# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# WineTestBot job submit page
#
# Copyright 2009 Ge van Geldorp
# Copyright 2012-2014, 2017-2018 Francois Gouget
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA

use strict;

package SubmitPage;

use ObjectModel::CGI::FreeFormPage;
our @ISA = qw(ObjectModel::CGI::FreeFormPage);

use CGI qw(:standard);
use Fcntl; # For O_XXX
use IO::Handle;
use POSIX qw(:fcntl_h); # For SEEK_XXX
use File::Basename;

use ObjectModel::BasicPropertyDescriptor;
use WineTestBot::Branches;
use WineTestBot::Config;
use WineTestBot::Engine::Notify;
use WineTestBot::Jobs;
use WineTestBot::Missions;
use WineTestBot::PatchUtils;
use WineTestBot::Steps;
use WineTestBot::Utils;
use WineTestBot::VMs;


#
# File upload
#

sub _GetStagingFilePath($)
{
  my ($self) = @_;

  return "$DataDir/staging/" . $self->GetCurrentSession()->Id . "-websubmit_$self->{FileName}";
}

sub _Upload($)
{
  my ($self) = @_;

  my $Src = $self->CGI->upload("Upload");
  if (defined $Src)
  {
    my $OldUMask = umask(002);
    if (open(my $Dst, ">", $self->_GetStagingFilePath()))
    {
      umask($OldUMask);
      my $Buffer;
      while (sysread($Src, $Buffer, 4096))
      {
        print $Dst $Buffer;
      }
      close($Dst);
    }
    else
    {
      umask($OldUMask);
      delete $self->{FileName};
      $self->{ErrField} = "Upload";
      $self->{ErrMessage} = "Unable to save the uploaded file";
      return undef;
    }
  }
  else
  {
    delete $self->{FileName};
    $self->{ErrField} = "Upload";
    $self->{ErrMessage} = "Unable to upload the file";
    return undef;
  }
  return 1;
}

sub _GetFileType($)
{
  my ($self) = @_;

  return 1 if (defined $self->{FileType});
  $self->{FileType} = "patch";

  my $Fh;
  if (!sysopen($Fh, $self->_GetStagingFilePath(), O_RDONLY))
  {
    $self->{ErrField} = "FileName";
    $self->{ErrMessage} = "Unable to open '$self->{FileName}'";
    return undef;
  }

  my $Buffer;
  if (sysread($Fh, $Buffer, 0x40))
  {
    # Unpack IMAGE_DOS_HEADER
    my @Fields = unpack "S30I", $Buffer;
    if ($Fields[0] == 0x5a4d)
    {
      seek $Fh, $Fields[30], SEEK_SET;
      if (sysread($Fh, $Buffer, 0x18))
      {
        @Fields = unpack "IS2I3S2", $Buffer;
        if ($Fields[0] == 0x00004550)
        {
          if (($Fields[7] & 0x2000) == 0)
          {
            $self->{FileType} = "exe";
          }
          else
          {
            $self->{FileType} = "dll";
          }
          if ($Fields[1] == 0x014c)
          {
            $self->{FileType} .= "32";
          }
          elsif ($Fields[1] == 0x8664)
          {
            $self->{FileType} .= "64";
          }
          else
          {
            $self->{FileType} = "patch";
          }
        }
      }
    }
    # zip files start with PK, 0x03, 0x04
    elsif ($Fields[0] == 0x4b50 && $Fields[1] == 0x0403)
    {
      $self->{FileType} = "zip";
    }
  }
  close($Fh);

  if ($self->{FileType} !~ /^(?:exe32|exe64|patch)$/)
  {
    $self->{ErrField} = "FileName";
    $self->{ErrMessage} = "Unsupported file type";
    return undef;
  }

  return 1;
}

sub _AnalyzePatch($)
{
  my ($self) = @_;

  $self->{Impacts} ||= GetPatchImpacts($self->_GetStagingFilePath());

  if (!$self->{Impacts}->{PatchedRoot} and
      !$self->{Impacts}->{PatchedModules} and
      !$self->{Impacts}->{PatchedTests})
  {
    $self->{ErrField} = "FileName";
    $self->{ErrMessage} = "'$self->{FileName}' is not a valid patch";
    return undef;
  }
  if ($self->{Impacts}->{TestUnitCount} == 0)
  {
    $self->{ErrField} = "FileName";
    $self->{ErrMessage} = "The patch does not impact the tests";
    return undef;
  }
  if ($self->{Impacts}->{TestUnitCount} > 1)
  {
    $self->{ErrField} = "FileName";
    $self->{ErrMessage} = "The patch contains changes to multiple tests";
    return undef;
  }
  return 1;
}


#
# State validation
#

sub _ValidateFileName($)
{
  my ($self) = @_;

  if (!defined $self->{FileName})
  {
    delete $self->{FileName};
    $self->{ErrField} = "FileName";
    $self->{ErrMessage} = "You must provide a file to test";
    return undef;
  }
  if (!IsValidFileName($self->{FileName}))
  {
    delete $self->{FileName};
    $self->{ErrField} = "FileName";
    $self->{ErrMessage} = "The filename contains invalid characters";
    return undef;
  }
  my $PropertyDescriptor = CreateSteps()->GetPropertyDescriptorByName("FileName");
  if ($PropertyDescriptor->GetMaxLength() - 32 - 1 < length($self->{FileName}))
  {
    delete $self->{FileName};
    $self->{ErrField} = "FileName";
    $self->{ErrMessage} = "The filename is too long";
    return undef;
  }

  return 1;
}

sub _ValidateVMSelection($;$)
{
  my ($self, $DeselectIncompatible) = @_;

  return undef if (!$self->_GetFileType());

  my @Deselected;
  foreach my $VMRow (@{$self->{VMRows}})
  {
    if ($self->{FileType} eq "exe64" and $VMRow->{VM}->Type eq "win32")
    {
      # This VM cannot run 64 bit executables
      $VMRow->{Incompatible} = 1;
      if ($VMRow->{Checked})
      {
        if ($DeselectIncompatible)
        {
          $VMRow->{Checked} = undef;
        }
        else
        {
          push @Deselected, $VMRow->{VM}->Name;
        }
      }
    }
    else
    {
      delete $VMRow->{Incompatible};
    }

    if ($VMRow->{Checked})
    {
      # Count VMs so we can provide defaults or issue an error when needed
      $self->{CheckedVMCount}++;
      # Set ShowRun64 if page 3 should offer to run both the 32 and 64 bit
      # version of a patch.
      $self->{ShowRun64} = 1 if ($VMRow->{VM}->Type eq "win64");
    }
  }
  if (@Deselected)
  {
    $self->{ErrMessage} = "The following VMs are incompatible and have been deselected: @Deselected";
    return undef;
  }
  return 1;
}

sub Validate($)
{
  my ($self) = @_;

  # There is nothing to validate for error page 0
  return $self->SUPER::Validate() if ($self->{Page} == 0);

  # Validate the state from all past pages
  if ($self->{Page} >= 1)
  {
    # Note that _GetFileType() assumes the file is a patch when it does not
    # recognize it. So call _AnalyzePatch() to make sure it is legit.
    if (!$self->_ValidateFileName() or !$self->_GetFileType() or
        ($self->{FileType} eq "patch" and !$self->_AnalyzePatch()))
    {
      # The helper functions all set the error message already
      return undef;
    }

    if (!defined $self->{Branch})
    {
      # Note that Page 1 should have provided a default
      # so there is no reason for it to still be undefined.
      $self->{ErrField} = "Branch";
      $self->{ErrMessage} = "You must specify the branch to test";
      return undef;
    }
    if (!CreateBranches()->GetItem($self->{Branch}))
    {
      $self->{ErrField} = "Branch";
      $self->{ErrMessage} = "The '$self->{Branch}' branch does not exist";
      return undef;
    }
  }

  if ($self->{Page} >= 2)
  {
    return undef if (!$self->_ValidateVMSelection());
    if (!$self->{CheckedVMCount})
    {
      $self->{ErrMessage} = "Select at least one VM";
      return undef;
    }
  }

  if ($self->{Page} >= 3)
  {
    if (($self->{FileType} eq "patch" and
         $self->{TestExecutable} !~ m/^[\w_.]+_test\.exe$/) or
        !IsValidFileName($self->{TestExecutable}))
    {
      $self->{ErrField} = "TestExecutable";
      $self->{ErrMessage} = "Invalid test executable filename";
      return undef;
    }

    if ($self->{CmdLineArg} eq "" and !$self->{NoCmdLineArgWarn})
    {
      $self->{ErrMessage} = "You did not specify a command line argument. ".
                            "This is most likely not correct, so please ".
                            "fix this. If you are sure that you really don't ".
                            'want a command line argument, press "Submit" '.
                            "again.";
      $self->{ErrField} = "CmdLineArg";
      $self->{NoCmdLineArgWarn} = 1;
      return undef;
    }
  }

  return $self->SUPER::Validate();
}


#
# Page state management
#

sub _GetParams($@)
{
  my $self = shift @_;
  map { $self->{$_} = $self->GetParam($_) } @_;
}

sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  # Reload the parameters from all pages so settings don't get lost
  # when going back to change something.

  $self->{Page} = $self->GetParam("Page");
  # Page is a hidden parameter so fix it instead of issuing an error
  $self->{Page} = 1 if (!defined $self->{Page} or $self->{Page} !~ /^[0-3]$/);
  $self->{LastPage} = $self->{Page};

  # Load the Page 1 parameters
  $self->_GetParams("FileName", "Branch", "Remarks");

  # Load the Page 2 parameters
  $self->_GetParams("ShowAll", "UserVMSelection");
  my $VMs = CreateVMs();
  $VMs->AddFilter("Type", ["win32", "win64", "wine"]);
  $VMs->FilterEnabledRole();

  my $SortedKeys = $VMs->SortKeysBySortOrder($VMs->GetKeys());
  foreach my $VMKey (@$SortedKeys)
  {
    my $VM = $VMs->GetItem($VMKey);
    my $VMRow = {
      VM => $VM,
      Field  => "vm_". $self->CGI->escapeHTML($VMKey),
      Extra => $VM->Role ne "base",
    };
    $VMRow->{Checked} = $self->GetParam($VMRow->{Field});
    push @{$self->{VMRows}}, $VMRow;
  }

  # Load the Page 3 parameters
  $self->_GetParams("TestExecutable", "CmdLineArg", "NoCmdLineArgWarn",
                    "Run64", "DebugLevel", "ReportSuccessfulTests");
  $self->{DebugLevel} = 1 if (!defined $self->{DebugLevel});

  # Load the Page 4 parameters
  $self->{JobKey} = $self->GetParam("JobKey");
  if (defined $self->{JobKey} and $self->{JobKey} !~ /^[0-9]+$/)
  {
    # JobKey is a hidden parameter so drop it instead of issuing an error
    delete $self->{JobKey};
  }

  $self->SUPER::_initialize($Request, $RequiredRole, undef);
}

sub _GenerateStateField($$)
{
  my ($self, $Name) = @_;

  if (defined $self->{$Name})
  {
    print "<input type='hidden' name='$Name' value='",
          $self->CGI->escapeHTML($self->{$Name}), "'>\n";
  }
}

sub _GenerateStateFields($)
{
  my ($self) = @_;

  $self->_GenerateStateField("Page");

  if ($self->{Page} != 1)
  {
    $self->_GenerateStateField("Branch");
    $self->_GenerateStateField("FileName");
    $self->_GenerateStateField("Remarks");
  }
  if ($self->{Page} != 2)
  {
    $self->_GenerateStateField("ShowAll");
    $self->_GenerateStateField("UserVMSelection");
    foreach my $VMRow (@{$self->{VMRows}})
    {
      next if ($VMRow->{Incompatible});
      if ($VMRow->{Checked})
      {
        print "<input type='hidden' name='$VMRow->{Field}' value='on'>\n";
      }
    }
  }
  if ($self->{Page} != 3)
  {
    # Don't save NoCmdLineArgWarn: let it be reset if the user goes back
    # so he gets warned again.
    $self->_GenerateStateField("TestExecutable");
    $self->_GenerateStateField("CmdLineArg");
    $self->_GenerateStateField("Run64");
    $self->_GenerateStateField("DebugLevel");
    $self->_GenerateStateField("ReportSuccessfulTests");
  }
}


#
# Page generation
#

sub GetTitle($)
{
  #my ($self) = @_;
  return "Submit a job";
}

sub GetHeaderText($)
{
  my ($self) = @_;

  if ($self->{Page} == 0)
  {
    return "Your job was successfully queued, but the job engine that takes " .
           "care of actually running it seems to be unavailable (perhaps it " .
           "crashed). Your job will remain queued until the engine is " .
           "restarted.";
  }
  elsif ($self->{Page} == 1)
  {
    return defined $self->{FileName} ? "" :
           "Specify the patch file that you want to upload and submit " .
           "for testing.<br>\n" .
           "You can also specify a Windows .exe file, this would normally be " .
           "a Wine test executable that you cross-compiled."
  }
  elsif ($self->{Page} == 2)
  {
    my $HeaderText = "Select the VMs on which you want to run your test.";
    my $VMs = CreateVMs();
    $VMs->AddFilter("Status", ["offline", "maintenance"]);
    if (!$VMs->IsEmpty())
    {
      $HeaderText .= "<br>NOTE: Offline VMs and those undergoing maintenance will not be able to run your tests right away.";
    }
    return $HeaderText;
  }

  return "";
}

sub GetPropertyDescriptors($)
{
  my ($self) = @_;

  # Note that this may be called for different pages. For instance first to
  # validate the properties of the page 1, then again to generate the form
  # fields of page 2. See _SetPage().
  if ($self->{Page} == 1)
  {
    $self->{PropertyDescriptors} ||= [
      CreateBasicPropertyDescriptor("Remarks", "Remarks", !1, !1, "A", 128),
    ];
  }
  elsif ($self->{Page} == 3)
  {
    $self->_GetFileType();
    my $IsPatch = ($self->{FileType} eq "patch");
    $self->{PropertyDescriptors} ||= [
      CreateBasicPropertyDescriptor("TestExecutable", "Test executable", !1, $IsPatch, "A", 50),
      CreateBasicPropertyDescriptor("CmdLineArg", "Command line arguments", !1, !1, "A", 50),
      CreateBasicPropertyDescriptor("Run64", "Run 64-bit tests in addition to 32-bit tests", !1, 1, "B", 1),
      CreateBasicPropertyDescriptor("DebugLevel", "Debug level (WINETEST_DEBUG)", !1, 1, "N", 2),
      CreateBasicPropertyDescriptor("ReportSuccessfulTests", "Report successful tests (WINETEST_REPORT_SUCCESS)", !1, 1, "B", 1),
    ];
  }
  return $self->SUPER::GetPropertyDescriptors();
}

sub GenerateFields($)
{
  my ($self) = @_;

  # Save the settings that will not be edited by this page
  $self->_GenerateStateFields();

  if ($self->{Page} == 0)
  {
    $self->_GenerateStateField("JobKey");
  }

  elsif ($self->{Page} == 1)
  {
    print "<div class='ItemProperty'><label>File</label>",
          "<div class='ItemValue'>";
    if (defined $self->{FileName})
    {
      $self->_GenerateStateField("FileName");
      print "<input type='submit' name='Action' value='Unset'/> $self->{FileName}";
    }
    else
    {
      print "<input type='file' name='Upload' size='64' maxlength='64'/>",
            "&nbsp;<span class='Required'>*</span>";
    }
    print  "</div></div>\n";

    my $Branches = CreateBranches();
    if (!defined $self->{Branch})
    {
      my $DefaultBranch = $Branches->GetDefaultBranch();
      $self->{Branch} = $DefaultBranch->GetKey() if ($DefaultBranch);
    }
    if (!$Branches->MultipleBranchesPresent())
    {
      $self->_GenerateStateField("Branch");
    }
    else
    {
      print "<div class='ItemProperty'><label>Branch</label>",
            "<div class='ItemValue'>",
            "<select name='Branch' size='1'>";
      my @SortedKeys = sort { $a cmp $b } @{$Branches->GetKeys()};
      foreach my $Key (@SortedKeys)
      {
        my $Branch = $Branches->GetItem($Key);
        print "<option value='", $self->CGI->escapeHTML($Key), "'";
        if (defined $self->{Branch} and $Key eq $self->{Branch})
        {
          print " selected";
        }
        print ">", $self->CGI->escapeHTML($Branch->Name), "</option>";
      }
      print "</select>&nbsp;<span class='Required'>*</span></div></div>\n";
    }
    # The other fields are taken care of by FreeFormPage.
    $self->{HasRequired} = 1;
  }

  elsif ($self->{Page} == 2)
  {
    $self->_GenerateStateField("ShowAll");
    print "<div class='CollectionBlock'><table>\n";
    print "<thead><tr><th class='Record'></th>\n";
    print "<th class='Record'>VM Name</th>\n";
    print "<th class='Record'>Description</th>\n";
    print "</thead><tbody>\n";

    my $Even = 1;
    foreach my $VMRow (@{$self->{VMRows}})
    {
      next if ($VMRow->{Incompatible});
      # Extra VMs may be hidden
      next if ($VMRow->{Extra} and !$VMRow->{Checked} and !$self->{ShowAll});

      # By default select the base VMs that are ready to run tasks
      my $VM = $VMRow->{VM};
      if (!$self->{UserVMSelection} and !$VMRow->{Extra} and
          $VM->Status !~ /^(?:offline|maintenance)$/)
      {
        $VMRow->{Checked} = 1;
      }

      print "<tr class='", ($Even ? "even" : "odd"),
            "'><td><input name='$VMRow->{Field}' type='checkbox'";
      $Even = !$Even;
      print " checked='checked'" if ($VMRow->{Checked});
      print "/></td>\n";

      print "<td>", $self->CGI->escapeHTML($VM->Name), "</td>\n";
      print "<td><details><summary>",
            $self->CGI->escapeHTML($VM->Description || $VM->Name);
      print " [", $VM->Status ,"]" if ($VM->Status =~ /^(?:offline|maintenance)$/);
      print "</summary>",
            $self->CGI->escapeHTML($VM->Details || "No details!"),
            "</details></td>";
      print "</tr>\n";
    }
    print "</tbody></table>\n";

    # From now on it's the user's VM selection, i.e. don't pick defaults
    $self->{UserVMSelection} = 1;
    $self->_GenerateStateField("UserVMSelection");
    print "</div><!--CollectionBlock-->\n";

    # Add a "Toggle All" pseudo action
    print <<EOF;
<script type='text/javascript'>
<!--
function ToggleAll()
{
  for (var i = 0; i < document.forms[0].elements.length; i++)
  {
    if (document.forms[0].elements[i].type == 'checkbox')
      document.forms[0].elements[i].checked = !(document.forms[0].elements[i].checked);
  }
}

// Only put javascript link in document if javascript is enabled
document.write("<div class='ItemActions'><a href='javascript:void(0)' onClick='ToggleAll();'>Toggle All<\\\/a><\\\/div>");
//-->
</script>
EOF

    # Add a Show base/all VMs button separate from the other actions
    print "<div class='ItemActions'>\n";
    print "<input type='submit' name='Action' value='",
          $self->{ShowAll} ? "Show base VMs" : "Show all VMs", "'/>\n";
    print "</div>\n";
  }

  elsif ($self->{Page} == 3)
  {
    $self->_GenerateStateField("NoCmdLineArgWarn");

    # Preserve these fields if they are not shown
    $self->_GenerateStateField("Run64") if (!$self->{ShowRun64} or $self->{FileType} ne "patch");
    $self->_GenerateStateField("TestExecutable") if ($self->{FileType} ne "patch");

    # The other fields are taken care of by FreeFormPage.
  }

  $self->SUPER::GenerateFields();
}

sub GetActions($)
{
  my ($self) = @_;

  my $Actions = $self->SUPER::GetActions();
  if ($self->{Page} == 0)
  {
    push @$Actions, "OK";
  }
  elsif ($self->{Page} == 1)
  {
    push @$Actions, "Next >";
  }
  elsif ($self->{Page} == 2)
  {
    push @$Actions, "< Prev", "Next >";
  }
  elsif ($self->{Page} == 3)
  {
    push @$Actions, "< Prev", "Submit";
  }

  return $Actions;
}

sub DisplayProperty($$)
{
  my ($self, $PropertyDescriptor) = @_;

  if ($self->{Page} == 3)
  {
    my $PropertyName = $PropertyDescriptor->GetName();
    if ($PropertyName eq "Run64")
    {
      return "" if (!$self->{ShowRun64} or $self->{FileType} ne "patch");
    }
    elsif ($PropertyName eq "TestExecutable")
    {
      return "" if ($self->{FileType} ne "patch");
    }
  }

  return $self->SUPER::DisplayProperty($PropertyDescriptor);
}

sub GetDisplayValue($$)
{
  my ($self, $PropertyDescriptor) = @_;

  return $self->{$PropertyDescriptor->GetName()};
}


#
# Page actions
#

sub _SetPage($$)
{
  my ($self, $Page) = @_;

  $self->{Page} = $Page;
  # Changing the page also changes the fields of the HTML form
  delete $self->{PropertyDescriptors};
}

sub OnUnset($)
{
  my ($self) = @_;

  if (!$self->_ValidateFileName())
  {
    # Ignore the error. What counts is not using a suspicious FileName.
    delete $self->{ErrField};
    delete $self->{ErrMessage};
  }
  elsif (defined $self->{FileName})
  {
    my $StagingFilePath = $self->_GetStagingFilePath();
    unlink($StagingFilePath) if ($StagingFilePath);
    delete $self->{FileName};
  }
  delete $self->{TestExecutable};
  delete $self->{CmdLineArg};

  return 1;
}

sub OnPage1Next($)
{
  my ($self) = @_;

  if (defined $self->{FileName})
  {
    return undef if (!$self->_ValidateFileName());
  }
  else
  {
    $self->{FileName} = $self->GetParam("Upload");
    return undef if (!$self->_ValidateFileName() or !$self->_Upload());
  }
  if (!$self->Validate() or !$self->_ValidateVMSelection("deselect"))
  {
    return undef;
  }

  # Set defaults
  if ((!defined $self->{TestExecutable} or !defined $self->{CmdLineArg}) and
      $self->{Impacts})
  {
    foreach my $TestInfo (values %{$self->{Impacts}->{Tests}})
    {
      next if (!$TestInfo->{UnitCount});
      if (!defined $self->{TestExecutable})
      {
        $self->{TestExecutable} = "$TestInfo->{ExeBase}.exe";
      }
      if (!defined $self->{CmdLineArg})
      {
        $self->{CmdLineArg} = (keys %{$TestInfo->{PatchedUnits}})[0];
      }
      last;
    }
  }
  if (!defined $self->{Run64})
  {
    # Whether we show it or not the default is true
    $self->{Run64} = 1;
  }

  $self->_SetPage(2);
  return 1;
}

sub OnPage2Next($)
{
  my ($self) = @_;

  return undef if (!$self->Validate);

  $self->_SetPage(3);
  return 1;
}

sub OnPage2Prev($)
{
  my ($self) = @_;

  $self->_SetPage(1);
  return 1;
}

sub OnPage3Prev($)
{
  my ($self) = @_;

  # Set to 0 instead of undef to record the user preference
  $self->{Run64} ||= 0;
  $self->{ReportSuccessfulTests} ||= 0;

  $self->_SetPage(2);

  # Don't try to generate page 2 from bad data (typically because of an invalid
  # FileName). Instead go back to page 1.
  return $self->Validate() ? 1 : $self->OnPage2Prev();
}


sub _SubmitJob($$)
{
  my ($self, $Staging) = @_;

  # See also Patches::Submit() in lib/WineTestBot/Patches.pm

  # First create a new job
  my $Jobs = CreateJobs();
  my $NewJob = $Jobs->Add();
  $NewJob->User($self->GetCurrentSession()->User);
  $NewJob->Priority(5);
  $NewJob->Remarks($self->{Remarks} || $self->{CmdLineArg} || "");
  my $Branch = CreateBranches()->GetItem($self->{Branch});
  $NewJob->Branch($Branch) if (defined $Branch);
  my $Steps = $NewJob->Steps;

  # Add steps and tasks for the 32 and 64 bit tests
  my $BuildStep;
  foreach my $Bits ("32", "64")
  {
    next if ($Bits eq "32" && $self->{FileType} eq "exe64");
    next if ($Bits eq "64" && $self->{FileType} eq "exe32");
    next if ($Bits eq "64" && $self->{FileType} eq "patch" && !defined $self->{Run64});

    my $Tasks;
    my $VMs = CreateVMs();
    $VMs->AddFilter("Type", $Bits eq "32" ? ["win32", "win64"] : ["win64"]);
    my $SortedKeys = $VMs->SortKeysBySortOrder($VMs->GetKeys());
    foreach my $VMKey (@$SortedKeys)
    {
      my $VM = $VMs->GetItem($VMKey);
      my $FieldName = "vm_" . $self->CGI->escapeHTML($VMKey);
      next if (!$self->GetParam($FieldName)); # skip unselected VMs

      if (!$Tasks)
      {
        if (!$BuildStep and $self->{FileType} eq "patch")
        {
          # This is a patch so add a build step...
          $BuildStep = $Steps->Add();
          $BuildStep->FileName($self->{FileName});
          $BuildStep->FileType($self->{FileType});
          $BuildStep->Type("build");
          $BuildStep->DebugLevel(0);

          # ...with a build task
          my $VMs = CreateVMs();
          $VMs->AddFilter("Type", ["build"]);
          $VMs->AddFilter("Role", ["base"]);
          my $BuildVM = ${$VMs->GetItems()}[0];
          my $Task = $BuildStep->Tasks->Add();
          $Task->VM($BuildVM);

          my $MissionStatement = "exe32";
          $MissionStatement .= ":exe64" if (defined $self->{Run64});
          my ($ErrMessage, $Missions) = ParseMissionStatement($MissionStatement);
          if (!defined $ErrMessage)
          {
            $Task->Timeout(GetBuildTimeout($self->{Impacts}, $Missions->[0]));
            $Task->Missions($MissionStatement);

            # Save the build step so the others can reference it
            (my $ErrKey, my $ErrProperty, $ErrMessage) = $Jobs->Save();
          }
          if (defined $ErrMessage)
          {
            $self->{ErrMessage} = $ErrMessage;
            return undef;
          }
        }

        # Then create the test step
        my $TestStep = $Steps->Add();
        if ($self->{FileType} eq "patch")
        {
          $TestStep->PreviousNo($BuildStep->No);
          my $TestExe = basename($self->{TestExecutable});
          $TestExe =~ s/_test\.exe$/_test64.exe/ if ($Bits eq "64");
          $TestStep->FileName($TestExe);
        }
        else
        {
          $TestStep->FileName($self->{FileName});
        }
        $TestStep->FileType("exe$Bits");
        $TestStep->Type("single");
        $TestStep->DebugLevel($self->{DebugLevel});
        $TestStep->ReportSuccessfulTests(defined $self->{ReportSuccessfulTests});
        $Tasks = $TestStep->Tasks;
      }

      # Then add a task for this VM
      my $Task = $Tasks->Add();
      $Task->VM($VM);
      $Task->Timeout($SingleTimeout);
      $Task->Missions("exe$Bits");
      $Task->CmdLineArg($self->{CmdLineArg});
    }
  }

  my ($Tasks, $MissionStatement, $Timeout);
  my $VMs = CreateVMs();
  $VMs->AddFilter("Type", ["wine"]);
  my $SortedKeys = $VMs->SortKeysBySortOrder($VMs->GetKeys());
  foreach my $VMKey (@$SortedKeys)
  {
    my $VM = $VMs->GetItem($VMKey);
    my $FieldName = "vm_" . $self->CGI->escapeHTML($VMKey);
    next if (!$self->GetParam($FieldName)); # skip unselected VMs

    if (!$Tasks)
    {
      # First create the Wine test step
      my $WineStep = $Steps->Add();
      $WineStep->FileName($self->{FileName});
      $WineStep->FileType($self->{FileType});
      $WineStep->Type("single");
      $WineStep->DebugLevel($self->{DebugLevel});
      $WineStep->ReportSuccessfulTests(defined $self->GetParam("ReportSuccessfulTests"));
      $Tasks = $WineStep->Tasks;

      $MissionStatement = ($self->{FileType} =~ /^(?:exe32|patch)$/) ? "win32" : "";
      if ($self->{FileType} eq "exe64" or
          ($self->{FileType} eq "patch" and defined $self->{Run64}))
      {
        $MissionStatement .= ":wow64";
      }
      $MissionStatement =~ s/^://;

      my ($ErrMessage, $Missions) = ParseMissionStatement($MissionStatement);
      if (defined $ErrMessage)
      {
        $self->{ErrMessage} = $ErrMessage;
        return undef;
      }
      $Missions = $Missions->[0];
      $Timeout = $self->{FileType} ne "patch" ?
                 $SingleTimeout :
                 GetBuildTimeout($self->{Impacts}, $Missions) +
                 GetTestTimeout($self->{Impacts}, $Missions);
    }

    # Then add a task for this VM
    my $Task = $Tasks->Add();
    $Task->VM($VM);
    $Task->Timeout($Timeout);
    $Task->Missions($MissionStatement);
    $Task->CmdLineArg($self->{CmdLineArg}) if ($self->{FileType} ne "patch");
  }

  # Now save it all (or whatever's left to save)
  my ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
  if (defined $ErrMessage)
  {
    $self->{ErrMessage} = $ErrMessage;
    return undef;
  }

  # Stage the test patch/executable so the job can pick it up
  if (!rename($Staging, "$DataDir/staging/job". $NewJob->Id ."_$self->{FileName}"))
  {
    $self->{ErrMessage} = "Could not stage '$self->{FileName}': $!\n";
    return undef;
  }

  # Switch Status to staging to indicate we are done setting up the job
  $NewJob->Status("staging");
  ($ErrKey, $ErrProperty, $ErrMessage) = $Jobs->Save();
  if (defined $ErrMessage)
  {
    $self->{ErrMessage} = $ErrMessage;
    return undef;
  }

  # Notify engine
  my $ErrMessage = RescheduleJobs();
  if (defined $ErrMessage)
  {
    $self->{ErrMessage} = $ErrMessage;
    $self->_SetPage(0);
    $self->{JobKey} = $NewJob->GetKey();
    return undef;
  }

  $self->Redirect("/JobDetails.pl?Key=". $NewJob->GetKey()); # does not return
  exit;
}

sub OnSubmit($)
{
  my ($self) = @_;

  return undef if (!$self->Validate());

  # Rename the staging file to avoid race conditions if the user clicks on
  # Submit multiple times
  my $OldStaging = $self->_GetStagingFilePath();
  my $Staging = CreateNewLink($OldStaging, "$DataDir/staging", $self->{FileName});
  if (!defined $Staging)
  {
    $self->{ErrMessage} = "Could not rename '$self->{FileName}': $!";
    return undef;
  }
  if (!unlink $OldStaging)
  {
    unlink $Staging;
    $self->{ErrMessage} = $!{ENOENT} ?
        "$self->{FileName} has already been submitted or has expired" :
        "Could not remove the staging '$self->{FileName}' file: $!";
    return undef;
  }

  if (!$self->_SubmitJob($Staging))
  {
    # Restore the file for the next attempt
    rename($Staging, $OldStaging);
    return undef;
  }
  return 1;
}

sub OnSetShowAllVMs($$)
{
  my ($self, $Value) = @_;

  # Call _ValidateVMSelection() to identify incompatible VMs so they are not
  # marked as Checked
  if (!$self->_ValidateVMSelection("deselect"))
  {
    # Ignore errors
    delete $self->{ErrField};
    delete $self->{ErrMessage};
  }
  $self->{ShowAll} = $Value;

  return undef;
}

sub OnOK($)
{
  my ($self) = @_;

  if (defined $self->{JobKey})
  {
    $self->Redirect("/JobDetails.pl?Key=$self->{JobKey}"); # does not return
  }
  else
  {
    $self->Redirect("/index.pl"); # does not return
  }
}

sub OnAction($$)
{
  my ($self, $Action) = @_;

  if ($Action eq "Next >")
  {
    return $self->{Page} == 2 ? $self->OnPage2Next() : $self->OnPage1Next();
  }
  elsif ($Action eq "< Prev")
  {
    return $self->{Page} == 3 ? $self->OnPage3Prev() : $self->OnPage2Prev();
  }
  elsif ($Action eq "Unset")
  {
    return $self->OnUnset();
  }
  elsif ($Action eq "Submit")
  {
    return $self->OnSubmit();
  }
  elsif ($Action eq "Show base VMs")
  {
    return $self->OnSetShowAllVMs(undef);
  }
  elsif ($Action eq "Show all VMs")
  {
    return $self->OnSetShowAllVMs(1);
  }
  elsif ($Action eq "OK")
  {
    return $self->OnOK();
  }

  return $self->SUPER::OnAction($Action);
}


package main;

my $Request = shift;

my $SubmitPage = SubmitPage->new($Request, "wine-devel");
$SubmitPage->GeneratePage();
