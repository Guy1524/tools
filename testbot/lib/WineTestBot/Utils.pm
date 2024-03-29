# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2009 Ge van Geldorp
# Copyright 2012-2018 Francois Gouget
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

package WineTestBot::Utils;

=head1 NAME

WineTestBot::Utils - Utility functions

=cut

use Exporter 'import';
our @EXPORT = qw(SecureConnection MakeSecureURL GetTaskURL GenerateRandomString
                 OpenNewFile CreateNewFile CreateNewLink CreateNewDir GetMTime
                 DurationToString BuildEMailRecipient IsValidFileName
                 BuildTag SanitizeTag LocaleName NotifyAdministrator
                 BatchQuote ShQuote ShArgv2Cmd);

use Fcntl;

use WineTestBot::Config;


#
# Web helpers
#

sub SecureConnection()
{
  return defined($ENV{"HTTPS"}) && $ENV{"HTTPS"} eq "on";
}

sub MakeSecureURL($)
{
  my ($URL) = @_;

  my $Protocol = ($UseSSL || SecureConnection()) ? "https://" : "http://";
  return $Protocol . ($ENV{"HTTP_HOST"} || $WebHostName) . $URL;
}

sub GetTaskURL($$$;$$)
{
  my ($JobId, $StepNo, $TaskNo, $ShowScreenshot, $ShowLog) = @_;
  my $StepTask = 100 * $StepNo + $TaskNo;
  my $URL = "/JobDetails.pl?Key=$JobId";
  $URL .= "&s$StepTask=1" if ($ShowScreenshot);
  $URL .= "&f$StepTask=$ShowLog" if ($ShowLog);
  return "$URL#k$StepTask";
}

sub DurationToString($;$)
{
  my ($Secs, $Raw) = @_;

  return "n/a" if (!defined $Secs);

  my @Parts;
  if (!$Raw)
  {
    my $Mins = int($Secs / 60);
    $Secs -= 60 * $Mins;
    my $Hours = int($Mins / 60);
    $Mins -= 60 * $Hours;
    my $Days = int($Hours / 24);
    $Hours -= 24 * $Days;
    push @Parts, "${Days}d" if ($Days);
    push @Parts, "${Hours}h" if ($Hours);
    push @Parts, "${Mins}m" if ($Mins);
  }
  if (!@Parts or int($Secs) != 0)
  {
    push @Parts, (@Parts or int($Secs) == $Secs) ?
                 int($Secs) ."s" :
                 sprintf('%.1fs', $Secs);
  }
  return join(" ", @Parts);
}

sub BuildEMailRecipient($$)
{
  my ($EMailAddress, $Name) = @_;

  if (! defined($EMailAddress))
  {
    return undef;
  }
  my $Recipient = "<" . $EMailAddress . ">";
  if ($Name)
  {
    $Recipient .= " ($Name)";
  }

  return $Recipient;
}

my $_LCLang;
my $_LocaleLang;
sub GetLanguageName($)
{
  my ($Code) = @_;
  local $@;

  return "Konkani" if ($Code eq "kok");

  if (!defined $_LCLang)
  {
    eval
    {
      require Locale::Codes;
      $_LCLang = new Locale::Codes 'language';
      $_LCLang->show_errors(0);
    };
    if (!$_LCLang)
    {
      $_LCLang = 0;
      $_LocaleLang = eval { require Locale::Language };
    }
  }
  my $Name = $_LCLang ? ($_LCLang->code2name($Code) || $Code) :
             $_LocaleLang ? eval { Locale::Language::code2language($Code) || $Code } :
             $Code;
  $Name =~ s/ \(.*$//;
  return $Name;
}

my $_LCCountry;
my $_LocaleCountry;
sub GetCountryName($)
{
  my ($Code) = @_;
  local $@;

  return "USA" if ($Code eq "US");
  return "Great Britain" if ($Code eq "GB");

  if (!defined $_LCCountry)
  {
    eval
    {
      require Locale::Codes;
      $_LCCountry = new Locale::Codes 'country';
      $_LCCountry->show_errors(0);
    };
    if (!$_LCCountry)
    {
      $_LCCountry = 0;
      $_LocaleCountry = eval { require Locale::Country };
    }
  }
  my $Name =  $_LCCountry ? ($_LCCountry->code2name($Code) || $Code) :
              $_LocaleCountry ? eval { Locale::Country::code2country($Code) || $Code } :
              $Code;
  $Name =~ s/(?:, | \().*$//;
  return $Name;
}


sub LocaleName($)
{
  my ($Locale) = @_;
  $Locale ||= "en_US"; # default

  if ($Locale =~ /^([a-z]+)_([A-Z]+)(?:\.[A-Z0-9-]+)?(?:@([a-z]+))?$/)
  {
    my ($Lang, $Country, $Modifier) = ($1, $2, $3);
    my $Name = GetLanguageName($Lang);
    $Name .= ":". GetCountryName($Country) if (uc($Lang) ne $Country);

    $Name .= " ($Modifier)" if ($Modifier);
    return $Name;
  }
  return $Locale;
}


#
# Temporary file helpers
#

sub GenerateRandomString($)
{
  my ($Len) = @_;

  my $RandomString = "";
  while (length($RandomString) < $Len)
  {
    my $Part = "0000" . sprintf("%lx", int(rand(2 ** 16)));
    $RandomString .= substr($Part, -4);
  }

  return substr($RandomString, 0, $Len);
}

sub OpenNewFile($$)
{
  my ($Dir, $Suffix) = @_;

  while (1)
  {
    my $fh;
    my $FileName = "$Dir/" . GenerateRandomString(32) . $Suffix;
    return ($fh, $FileName) if (sysopen($fh, $FileName, O_CREAT | O_EXCL | O_WRONLY));

    # This is not an error that will be fixed by trying a different filename
    return (undef, undef) if (!$!{EEXIST});
  }
}

sub CreateNewFile($$)
{
  my ($Dir, $Suffix) = @_;

  my ($fh, $FileName) = OpenNewFile($Dir, $Suffix);
  close($fh) if ($fh);
  return $FileName;
}

sub CreateNewLink($$$)
{
  my ($OldFileName, $Dir, $Suffix) = @_;

  while (1)
  {
    my $Link = "$Dir/" . GenerateRandomString(32) . $Suffix;
    return $Link if (link $OldFileName, $Link);

    # This is not an error that will be fixed by trying a different path
    return undef if (!$!{EEXIST});
  }
}

sub CreateNewDir($$)
{
  my ($Dir, $Suffix) = @_;

  while (1)
  {
    my $Path = "$Dir/" . GenerateRandomString(32) . $Suffix;
    return $Path if (mkdir $Path);

    # This is not an error that will be fixed by trying a different path
    return undef if (!$!{EEXIST});
  }
}

sub GetMTime($)
{
  my ($Filename) = @_;
  return (stat($Filename))[9] || 0;
}


#
# WineTest helpers
#

sub SanitizeTag($)
{
  my ($Tag) = @_;
  $Tag =~ s/[^a-zA-Z0-9.-]/-/g;
  return substr($Tag, 0, 30);
}

sub BuildTag($;$)
{
  my ($VMName, $Tag) = @_;

  $Tag = $Tag ? "$VMName-$Tag" : $VMName;
  $Tag =~ s/^$TagPrefix//;
  return SanitizeTag("$TagPrefix-$Tag");
}


#
# EMail helper
#

sub NotifyAdministrator($$)
{
  my ($Subject, $Body) = @_;

  if (open(my $fh, "|/usr/sbin/sendmail -oi -t -odq"))
  {
    require WineTestBot::Log;
    WineTestBot::Log::LogMsg("Notifying administrator: $Subject\n");
    print $fh <<"EOF";
From: $RobotEMail
To: $AdminEMail
Subject: $Subject

$Body
EOF
    close($fh);
  }
  else
  {
    require WineTestBot::Log;
    WineTestBot::Log::LogMsg("Could not send administrator notification: $!\n");
    WineTestBot::Log::LogMsg("  Subject: $Subject\n");
    WineTestBot::Log::LogMsg("  Body: $Body\n");
  }
}


#
# Shell helpers
#

=pod
=over 12

=item C<IsValidFileName()>

Returns true if the filename is valid on Unix and Windows systems.

This also ensures this is not a trick filename such as '../important/file'.

=back
=cut

sub IsValidFileName($)
{
  my ($FileName) = @_;
  return $FileName !~ m~[<>:"/\\|?*]~;
}

=pod
=over 12

=item C<BatchQuote()>

Quotes strings so they can be used in Windows batch files.

Note that escaping is subtly different between the command line, batch files
and inside for loops in batch files! This function ignores the latter case.

=back
=cut
sub BatchQuote($)
{
  my ($Str)=@_;

  $Str =~ s/"/\\"/g;
  # Backslashes don't need to be doubled, they only take on a special meaning
  # when followed by a double quote. Single quotes and backquotes don't have
  # a special meaning either.
  $Str =~ s/%/%%/g;
  $Str =~ s/\^/^^/g;
  return "\"$Str\"";
}

=pod
=over 12

=item C<ShQuote()>

Quotes strings so they can be used in shell commands.

Note that this implies escaping '$'s and '`'s which may not be appropriate
in another context.

=back
=cut

sub ShQuote($)
{
  my ($Str)=@_;
  return $Str if ($Str =~ /^[a-zA-Z0-9\/=:.,+_-]+$/);

  $Str =~ s%\\%\\\\%g;
  $Str =~ s%\$%\\\$%g;
  $Str =~ s%\"%\\\"%g;
  $Str =~ s%\`%\\\`%g;
  return "\"$Str\"";
}

=pod
=over 12

=item C<ShArgv2Cmd()>

Converts an argument list into a command line suitable for use in a shell.

See also ShQuote().

=back
=cut

sub ShArgv2Cmd(@)
{
  return join(' ', map { ShQuote($_) } @_);
}

1;
