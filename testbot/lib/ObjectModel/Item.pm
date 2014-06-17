# Copyright 2009 Ge van Geldorp
# Copyright 2012-2014 Francois Gouget
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

package ObjectModel::Item;

=head1 NAME

ObjectModel::Item - Base class for items

=cut

use ObjectModel::BackEnd;
use ObjectModel::Collection;
use ObjectModel::PropertyDescriptor;

use vars qw(@ISA @EXPORT_OK);

require Exporter;
@ISA = qw(Exporter);
@EXPORT_OK = qw(&new);

sub new($$@)
{
  my $class = shift;
  my ($Collection) = @_;

  my $self = {};
  $self->{TableName} = $Collection->{TableName};
  $self->{ScopeItems} = $Collection->{AllScopeItems}->{ref($Collection)};
  $self->{AllScopeItems} = $Collection->{AllScopeItems};
  $self->{PropertyDescriptors} = $Collection->{PropertyDescriptors};
  $self->{MasterColNames} = $Collection->{MasterColNames};
  $self->{MasterColValues} = $Collection->{MasterColValues};
  $self->{MasterKey} = ObjectModel::Collection::ComputeMasterKey($self->{MasterColValues});
  $self->{IsNew} = 1;
  $self->{IsModified} = !1;
  foreach my $PropertyDescriptor (@{$self->{PropertyDescriptors}})
  {
    foreach my $ColName (@{$PropertyDescriptor->GetColNames()})
    {
      $self->{ColValues}{$ColName} = undef;
    }
    if ($PropertyDescriptor->GetClass() eq "Itemref")
    {
      $self->{Itemrefs}{$PropertyDescriptor->GetName()} = undef;
    }
    elsif ($PropertyDescriptor->GetClass() eq "Detailref")
    {
      $self->{Details}{$PropertyDescriptor->GetName()} = undef;
    }
  }
  $self = bless $self, $class;
  $self->_initialize(@_);
  return $self;
}

sub _initialize($$)
{
  #my ($self, $Collection) = @_;
}

sub InitializeNew($$)
{
  my ($self, $_Collection) = @_;

  $self->{IsModified} = !1;
}

sub GetPropertyDescriptors($)
{
  my ($self) = @_;

  return $self->{PropertyDescriptors};
}

sub GetPropertyDescriptorByName($$)
{
  my ($self, $Name) = @_;

  foreach my $PropertyDescriptor (@{$self->{PropertyDescriptors}})
  {
    if ($PropertyDescriptor->GetName() eq $Name)
    {
      return $PropertyDescriptor;
    }
  }

  return undef;
}

sub GetTableName($)
{
  my ($self) = @_;

  return $self->{TableName};
}

sub GetIsNew($)
{
  my ($self) = @_;

  return $self->{IsNew};
}

sub GetIsModified($)
{
  my ($self) = @_;

  return $self->{IsModified};
}

sub GetColValue($$)
{
  my ($self, $ColName) = @_;

  if (! exists($self->{ColValues}{$ColName}))
  {
    die "Unknown ColName $ColName";
  }

  return $self->{ColValues}{$ColName};
}

sub PutColValue($$$)
{
  my ($self, $ColName, $Value) = @_;

  if (! exists($self->{ColValues}{$ColName}))
  {
    die "Unknown ColName $ColName";
  }
  if (! defined($self->{ColValues}{$ColName}) ||
      $self->{ColValues}{$ColName} ne $Value)
  {
    $self->{ColValues}{$ColName} = $Value;
    $self->{IsModified} = 1;
  }
}

sub ValuesDiffer($$$)
{
  my ($self, $Val1, $Val2) = @_;

  if (defined($Val1))
  {
    if (defined($Val2))
    {
      if ($Val1 ne $Val2)
      {
        return 1;
      }
    }
    else
    {
      return 1;
    }
  }
  elsif (defined($Val2))
  {
    return 1;
  }

  return !1;
}

sub AUTOLOAD
{
  my $self = shift;

  my $PropertyName = $ObjectModel::Item::AUTOLOAD;
  # strip fully-qualified portion
  $PropertyName =~ s/.*://;
  if ($PropertyName eq "DESTROY")
  {
    return;
  }
  foreach my $PropertyDescriptor (@{$self->{PropertyDescriptors}})
  {
    if ($PropertyName eq $PropertyDescriptor->GetName())
    {
      if ($PropertyDescriptor->GetClass() eq "Basic" or
          $PropertyDescriptor->GetClass() eq "Enum")
      {
        if (@_)
        {
          my $Value = shift;
          if ($self->ValuesDiffer($Value, $self->{ColValues}{$PropertyName}))
          {
            $self->{ColValues}{$PropertyName} = $Value;
            $self->{IsModified} = 1;
          }
        }
        return $self->{ColValues}{$PropertyName};
      }
      elsif($PropertyDescriptor->GetClass() eq "Itemref")
      {
        my $ColNames = $PropertyDescriptor->GetColNames();
        if (@{$ColNames} != 1)
        {
          die "Multiple key components not supported";
        }
        if (@_)
        {
          $self->{Itemrefs}{$PropertyName} = shift;
          if ($self->ValuesDiffer($self->{ColValues}{@{$ColNames}[0]},
                                  $self->{Itemrefs}{$PropertyName}->GetKey()))
          {
            $self->{IsModified} = 1;
            $self->{ColValues}{@{$ColNames}[0]} = $self->{Itemrefs}{$PropertyName}->GetKey();
          }
        }
        elsif (! defined($self->{Itemrefs}{$PropertyName}))
        {
          my $Collection = &{$PropertyDescriptor->GetCreator()}($self);
          my $Item = $Collection->GetItem($self->{ColValues}{@{$ColNames}[0]});
          $self->{Itemrefs}{$PropertyName} = $Item;
        }
        return $self->{Itemrefs}{$PropertyName};
      }
      elsif($PropertyDescriptor->GetClass() eq "Detailref")
      {
        if (! defined($self->{Details}{$PropertyName}))
        {
          my $Detail = &{$PropertyDescriptor->GetCreator()}(undef, $self);
          $self->{Details}{$PropertyName} = $Detail;
          return $Detail;
        }

        return $self->{Details}{$PropertyName};
      }
      else
      {
        die "Unknown PropertyDescriptor Class " . $PropertyDescriptor->GetClass();
      }
    }
  }

  die "Unknown property or method $PropertyName";
}

sub GetMasterKey($)
{
  my ($self) = @_;

  my $ColNamePrefix = ref($self);
  $ColNamePrefix =~ s/.*://;
  my @MasterColNames, my @MasterColValues;
  if (defined($self->{MasterColNames}))
  {
    @MasterColNames = @{$self->{MasterColNames}};
    @MasterColValues = @{$self->{MasterColValues}};
  }
  foreach my $PropertyDescriptor (@{$self->GetPropertyDescriptors()})
  {
    if ($PropertyDescriptor->GetIsKey())
    {
      foreach my $ColName (@{$PropertyDescriptor->GetColNames()})
      {
        @MasterColNames[scalar @MasterColNames] = $ColNamePrefix . $ColName;
        @MasterColValues[scalar @MasterColValues] = $self->GetColValue($ColName);
      }
    }
  }

  return (\@MasterColNames, \@MasterColValues);
}

sub ResetModified($)
{
  my ($self) = @_;

  $self->{IsNew} = !1;
  $self->{IsModified} = !1;
}

sub GetKey($)
{
  my ($self) = @_;

  my $Key = undef;
  foreach my $PropertyDescriptor (@{$self->{PropertyDescriptors}})
  {
    if ($PropertyDescriptor->GetIsKey())
    {
      foreach my $ColName (@{$PropertyDescriptor->GetColNames()})
      {
        if (defined($Key))
        {
          $Key .= "#@#";
        }
        else
        {
          $Key = "";
        }
        my $KeyPart = $self->{ColValues}{$ColName};
        if (defined($KeyPart))
        {
          $Key .= $KeyPart;
        }
      }
    }
  }

  return $Key;
}

sub GetFullKey($)
{
  my ($self) = @_;

  return undef if (!defined $self->{MasterKey});
  return $self->{MasterKey} . $self->GetKey();
}

sub GetKeyComponents($)
{
  my ($self) = @_;

  my @KeyComponents;
  foreach my $PropertyDescriptor (@{$self->{PropertyDescriptors}})
  {
    if ($PropertyDescriptor->GetIsKey())
    {
      foreach my $ColName (@{$PropertyDescriptor->GetColNames()})
      {
        $KeyComponents[@KeyComponents] = $self->{ColValues}{$ColName};
      }
    }
  }

  return @KeyComponents;
}

sub ValidateProperty($$)
{
  my ($self, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();
  return $PropertyDescriptor->ValidateValue($self->$PropertyName,
                                            $self->GetIsNew());
}

sub Validate($)
{
  my ($self) = @_;

  foreach my $PropertyDescriptor (@{$self->{PropertyDescriptors}})
  {
    my $ErrMessage = $self->ValidateProperty($PropertyDescriptor);
    if (defined($ErrMessage))
    {
      return ($PropertyDescriptor->GetName(), $ErrMessage);
    }
  }

  foreach my $PropertyDescriptor (@{$self->{PropertyDescriptors}})
  {
    if ($PropertyDescriptor->GetClass() eq "Detailref")
    { 
      my $Detail = $self->{Details}{$PropertyDescriptor->GetName()};
      my ($ErrKey, $ErrProperty, $ErrMessage) = $Detail->Validate();
      if (defined($ErrMessage))
      {
        return (undef, $ErrMessage);
      }
    }
  }

  return (undef, undef);
}

sub OnDelete($)
{
  my ($self) = @_;

  foreach my $PropertyDescriptor (@{$self->{PropertyDescriptors}})
  {
    if ($PropertyDescriptor->GetClass() eq "Detailref")
    {
      my $PropertyName = $PropertyDescriptor->GetName();
      my $Detailref = $self->$PropertyName;
      my $ErrMessage = $Detailref->DeleteAll();
      if (defined($ErrMessage))
      {
        return $ErrMessage;
      }
    }
  }

  return undef;
}

sub OnSaved($)
{
  my ($self) = @_;

  $self->ResetModified();
}

sub Save($)
{
  my ($self) = @_;

  my ($ErrProperty, $ErrMessage) = $self->Validate();
  if (defined($ErrMessage))
  {
    return ($ErrProperty, $ErrMessage);
  }

  $self->GetBackEnd()->SaveItem($self);

  foreach my $PropertyDescriptor (@{$self->GetPropertyDescriptors()})
  {
    if ($PropertyDescriptor->GetClass() eq "Detailref")
    {
      my $Detail = $self->{Details}{$PropertyDescriptor->GetName()};
      if (defined($Detail))
      {
        $Detail->SaveNoValidate();
      }
    }
  }

  $self->OnSaved();

  return (undef, undef);
}

sub KeyChanged($)
{
  my ($self) = @_;

  my ($MasterColNames, $MasterColValues);
  foreach my $PropertyDescriptor (@{$self->GetPropertyDescriptors()})
  {
    if ($PropertyDescriptor->GetClass() eq "Detailref")
    {
      if (! defined($MasterColValues))
      {
        ($MasterColNames, $MasterColValues) = $self->GetMasterKey();
      }
      my $Detail = $self->{Details}{$PropertyDescriptor->GetName()};
      $Detail->MasterKeyChanged($MasterColValues);
    }
  }
}

sub MasterKeyChanged($$)
{
  my ($self, $MasterColValues) = @_;

  my $Key = $self->GetKey();
  my $FullKey = $self->GetFullKey($Key);
  delete($self->{ScopeItems}->{$FullKey}) if (defined $FullKey);

  $self->{MasterColValues} = $MasterColValues;
  $self->{MasterKey} = ObjectModel::Collection::ComputeMasterKey($MasterColValues);
  $FullKey = $self->GetFullKey($Key);
  $self->{ScopeItems}->{$FullKey} = $self if (defined $FullKey);

  $self->KeyChanged();
}

sub GetMasterCols($)
{
  my ($self) = @_;

  return ($self->{MasterColNames}, $self->{MasterColValues});
}

1;
