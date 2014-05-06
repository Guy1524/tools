# Copyright 2009 Ge van Geldorp
# Copyright 2012 Francois Gouget
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

package WineTestBot::PendingPatchSet;

=head1 NAME

WineTestBot::PendingPatchSet - An object tracking a pending patchset

=head1 DESCRIPTION

A patchset is a set of patches that depend on each other. They are numbered so
that one knows in which order to apply them. This is typically indicated by a
subject of the form '[3/5] Subject'. This means one must track which patchset
a patch belongs to so it is tested (and applied) together with the earlier
parts rather than in isolation. Furthermore the parts of the set may arrive in
the wrong order so processing of later parts must be deferred until the earlier
ones have been received.

The WineTestBot::PendingPatchSet class is where this tracking is implemented.

=cut

use WineTestBot::Config;
use WineTestBot::Patches;
use WineTestBot::Utils;
use WineTestBot::WineTestBotObjects;

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotItem Exporter);

=pod
=over 12

=item C<CheckSubsetComplete()>

Returns true if all the patches needed for the specified part in the patchset
have been received.

=back
=cut

sub CheckSubsetComplete
{
  my $self = shift;
  my $MaxPart = $_[0];

  my $Parts = $self->Parts;
  my $MissingPart = !1;
  for (my $PartNo = 1; $PartNo <= $MaxPart && ! $MissingPart;
       $PartNo++)
  {
    $MissingPart = ! defined($Parts->GetItem($PartNo));
  }

  return ! $MissingPart;
}

=pod
=over 12

=item C<CheckComplete()>

Returns true if all the patches of the patchset have been received.

=back
=cut

sub CheckComplete
{
  my $self = shift;

  return $self->CheckSubsetComplete($self->TotalParts)
}

=pod
=over 12

=item C<SubmitSubset()>

Combines the patches leading to the specified part in the patchset, and then
calls WineTestBot::Patch::Submit() so it gets scheduled for testing.

=back
=cut

sub SubmitSubset
{
  my $self = shift;
  my ($MaxPart, $FinalPatch) = @_;

  my $CombinedFileName = "$DataDir/staging/" . GenerateRandomString(32) .
                         "_patch";
  while (-e $CombinedFileName)
  {
    $CombinedFileName = "$DataDir/staging/" . GenerateRandomString(32) .
                        "_patch";
  }

  if (! open(COMBINED, ">$CombinedFileName"))
  {
    return "Can't create combined patch file";
  }

  my $Parts = $self->Parts;
  for (my $PartNo = 1; $PartNo <= $MaxPart; $PartNo++)
  {
    my $Part = $Parts->GetItem($PartNo);
    if (defined($Part))
    {
      if (open(PART, "<$DataDir/patches/" . $Part->Patch->Id))
      {
        print COMBINED <PART>;
        close(PART);
      }
    }
  }

  close(COMBINED);

  my $ErrMessage = $FinalPatch->Submit($CombinedFileName, 1);
  unlink($CombinedFileName);

  return $ErrMessage;
}

=pod
=over 12

=item C<Submit()>

Submits the last patch in the patchset.

=back
=cut

sub Submit
{
  my $self = shift;
  my $FinalPatch = $_[0];

  return $self->SubmitSubset($self->TotalParts, $FinalPatch);
}

package WineTestBot::PendingPatchSets;

=head1 NAME

WineTestBot::PendingPatchSets - A collection of WineTestBot::PendingPatchSet objects

=cut

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::DetailrefPropertyDescriptor;
use WineTestBot::Config;
use WineTestBot::PendingPatches;
use WineTestBot::Patches;
use WineTestBot::Utils;
use WineTestBot::WineTestBotObjects;

use vars qw(@ISA @EXPORT @PropertyDescriptors);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotCollection Exporter);
@EXPORT = qw(&CreatePendingPatchSets);

my @PropertyDescriptors;

BEGIN
{
  @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("EMail", "EMail of series author", 1, 1, "A", 40),
    CreateBasicPropertyDescriptor("TotalParts", "Expected number of parts in series", 1, 1, "N", 2),
    CreateDetailrefPropertyDescriptor("Parts", "Parts received so far", !1, !1, \&CreatePendingPatches),
  );
}

sub CreateItem
{
  my $self = shift;

  return WineTestBot::PendingPatchSet->new($self);
}

=pod
=over 12

=item C<NewSubmission()>

Adds a new part to the current patchset and submits it as well as all the
other parts for which all the previous parts are available. If the new part
makes the patchset complete, then the patchset itself is deleted.

=back
=cut

sub NewSubmission
{
  my $self = shift;

  my $Patch = $_[0];
  if (! defined($Patch->FromEMail))
  {
    $Patch->Disposition("Unable to determine series author");
    return undef;
  }

  my $Subject = $Patch->Subject;
  $Subject =~ s/32\/64//;
  $Subject =~ s/64\/32//;
  $Subject =~ m/(\d+)\/(\d+)/;
  my $PartNo = int($1);
  my $MaxPartNo = int($2);

  my $Set = $self->GetItem($self->CombineKey($Patch->FromEMail, $MaxPartNo));
  if (! defined($Set))
  {
    $Set = $self->Add();
    $Set->EMail($Patch->FromEMail);
    $Set->TotalParts($MaxPartNo);
  }

  my $Parts = $Set->Parts;
  my $Part = $Parts->GetItem($PartNo);
  if (! defined($Part))
  {
    $Part = $Parts->Add();
    $Part->No($PartNo);
  }

  $Part->Patch($Patch);

  my ($ErrKey, $ErrProperty, $ErrMessage) = $self->Save();
  if (defined($ErrMessage))
  {
    $Patch->Disposition("Error occurred during series processing");
  }

  if (! $Set->CheckSubsetComplete($PartNo))
  {
    $Patch->Disposition($Patch->AffectsTests ? "Set not complete yet" :
                        "Patch doesn't affect tests");
  }
  else
  {
    my $AllPartsAvailable = 1;
    while ($PartNo <= $Set->TotalParts && $AllPartsAvailable &&
           ! defined($ErrMessage))
    {
      my $Part = $Parts->GetItem($PartNo);
      if (defined($Part))
      {
        if ($Part->Patch->AffectsTests)
        {
          $ErrMessage = $Set->SubmitSubset($PartNo, $Part->Patch);
        }
        else
        {
          $Part->Patch->Disposition("Patch doesn't affect tests");
        }
        my $ErrProperty;
        ($ErrProperty, $ErrMessage) = $Part->Patch->Save();
      }
      else
      {
        $AllPartsAvailable = !1;
      }
      $PartNo++;
    }
    if ($AllPartsAvailable && ! defined($ErrMessage))
    {
      $self->DeleteItem($Set);
    }
  }

  return $ErrMessage;
}

=pod
=over 12

=item C<CheckForCompleteSet()>

Goes over the pending patchsets and submits the patches for all those that
are complete. See WineTestBot::PendingPatchSet::Submit().
The WineTestBot::PendingPatchSet objects of all complete patchsets are also
deleted.

Note that this only submits the last patch in the set, because each part of a
patchset is submitted as it becomes available so the earlier parts are supposed
to have been submitted already.

=back
=cut

sub CheckForCompleteSet
{
  my $self = shift;

  my $ErrMessage;
  foreach my $Set (@{$self->GetItems()})
  {
    if ($Set->CheckComplete())
    {
      my $Patch = $Set->Parts->GetItem($Set->TotalParts)->Patch;
      my $SetErrMessage = $Set->Submit($Patch);
      if (defined($SetErrMessage))
      {
        if (! defined($ErrMessage))
        {
          $ErrMessage = $SetErrMessage;
        }
      }
      else
      {
        $Patch->Save();
      }
      $self->DeleteItem($Set);
    }
  }

  return $ErrMessage;
}

sub CreatePendingPatchSets(;$)
{
  my ($ScopeObject) = @_;
  return WineTestBot::PendingPatchSets->new("PendingPatchSets", "PendingPatchSets", "PendingPatchSet", \@PropertyDescriptors, $ScopeObject);
}

1;
