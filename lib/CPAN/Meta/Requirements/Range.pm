use 5.006; # keep at v5.6 for CPAN.pm
use strict;
use warnings;
package CPAN::Meta::Requirements::Range;
# ABSTRACT: a set of version requirements for a CPAN dist

our $VERSION = '2.141';

use Carp ();

=head1 SYNOPSIS

  use CPAN::Meta::Requirements::Range;

  my $range = CPAN::Meta::Requirements::Range->with_minimum(1);

  $range = $range->with_maximum('v2.2');

  my $stringified = $range->as_string;

=head1 DESCRIPTION

A CPAN::Meta::Requirements::Range object models a set of version constraints like
those specified in the F<META.yml> or F<META.json> files in CPAN distributions,
and as defined by L<CPAN::Meta::Spec>;
It can be built up by adding more and more constraints, and it will reduce them
to the simplest representation.

Logically impossible constraints will be identified immediately by thrown
exceptions.

=cut

# To help ExtUtils::MakeMaker bootstrap CPAN::Meta::Requirements on perls
# before 5.10, we fall back to the EUMM bundled compatibility version module if
# that's the only thing available.  This shouldn't ever happen in a normal CPAN
# install of CPAN::Meta::Requirements, as version.pm will be picked up from
# prereqs and be available at runtime.

BEGIN {
  eval "use version ()"; ## no critic
  if ( my $err = $@ ) {
    eval "use ExtUtils::MakeMaker::version" or die $err; ## no critic
  }
}

sub _clone {
  return (bless { } => $_[0]) unless ref $_[0];

  my ($s) = @_;
  my %guts = (
    (exists $s->{minimum} ? (minimum => version->new($s->{minimum})) : ()),
    (exists $s->{maximum} ? (maximum => version->new($s->{maximum})) : ()),

    (exists $s->{exclusions}
      ? (exclusions => [ map { version->new($_) } @{ $s->{exclusions} } ])
      : ()),
  );

  bless \%guts => ref($s);
}

=method with_exact_version

  $range->with_exact_version( $version );

This sets the version required to I<exactly> the given
version.  No other version would be considered acceptable.

This method returns the version range object.

=cut

sub with_exact_version {
  my ($self, $version, $module) = @_;
  $module = 'module' unless defined $module;
  $self = $self->_clone;

  unless ($self->accepts($version)) {
    $self->_reject_requirements(
      $module,
      "exact specification $version outside of range " . $self->as_string
    );
  }

  return CPAN::Meta::Requirements::Range::_Exact->_new($version);
}

sub _simplify {
  my ($self, $module) = @_;

  if (defined $self->{minimum} and defined $self->{maximum}) {
    if ($self->{minimum} == $self->{maximum}) {
      if (grep { $_ == $self->{minimum} } @{ $self->{exclusions} || [] }) {
        $self->_reject_requirements(
          $module,
          "minimum and maximum are both $self->{minimum}, which is excluded",
        );
      }

      return CPAN::Meta::Requirements::Range::_Exact->_new($self->{minimum});
    }

    if ($self->{minimum} > $self->{maximum}) {
      $self->_reject_requirements(
        $module,
        "minimum $self->{minimum} exceeds maximum $self->{maximum}",
      );
    }
  }

  # eliminate irrelevant exclusions
  if ($self->{exclusions}) {
    my %seen;
    @{ $self->{exclusions} } = grep {
      (! defined $self->{minimum} or $_ >= $self->{minimum})
      and
      (! defined $self->{maximum} or $_ <= $self->{maximum})
      and
      ! $seen{$_}++
    } @{ $self->{exclusions} };
  }

  return $self;
}

=method with_minimum

  $range->with_minimum( $version );

This adds a new minimum version requirement.  If the new requirement is
redundant to the existing specification, this has no effect.

Minimum requirements are inclusive.  C<$version> is required, along with any
greater version number.

This method returns the version range object.

=cut

sub with_minimum {
  my ($self, $minimum, $module) = @_;
  $module = 'module' unless defined $module;
  $self = $self->_clone;

  if (defined (my $old_min = $self->{minimum})) {
    $self->{minimum} = (sort { $b cmp $a } ($minimum, $old_min))[0];
  } else {
    $self->{minimum} = $minimum;
  }

  return $self->_simplify($module);
}

=method with_maximum

  $range->with_maximum( $version );

This adds a new maximum version requirement.  If the new requirement is
redundant to the existing specification, this has no effect.

Maximum requirements are inclusive.  No version strictly greater than the given
version is allowed.

This method returns the version range object.

=cut

sub with_maximum {
  my ($self, $maximum, $module) = @_;
  $module = 'module' unless defined $module;
  $self = $self->_clone;

  if (defined (my $old_max = $self->{maximum})) {
    $self->{maximum} = (sort { $a cmp $b } ($maximum, $old_max))[0];
  } else {
    $self->{maximum} = $maximum;
  }

  return $self->_simplify($module);
}

=method with_exclusion

  $range->with_exclusion( $version );

This adds a new excluded version.  For example, you might use these three
method calls:

  $range->with_minimum( '1.00' );
  $range->with_maximum( '1.82' );

  $range->with_exclusion( '1.75' );

Any version between 1.00 and 1.82 inclusive would be acceptable, except for
1.75.

This method returns the requirements object.

=cut

sub with_exclusion {
  my ($self, $exclusion, $module) = @_;
  $module = 'module' unless defined $module;
  $self = $self->_clone;

  push @{ $self->{exclusions} ||= [] }, $exclusion;

  return $self->_simplify($module);
}

sub _as_modifiers {
  my ($self) = @_;
  my @mods;
  push @mods, [ add_minimum => $self->{minimum} ] if exists $self->{minimum};
  push @mods, [ add_maximum => $self->{maximum} ] if exists $self->{maximum};
  push @mods, map {; [ add_exclusion => $_ ] } @{$self->{exclusions} || []};
  return \@mods;
}

=method as_struct

  $range->as_struct( $module );

This returns a data structure containing the version requirements. This should
not be used for version checks (see L</accepts_module> instead).

=cut

sub as_struct {
  my ($self) = @_;

  return 0 if ! keys %$self;

  my @exclusions = @{ $self->{exclusions} || [] };

  my @parts;

  for my $tuple (
    [ qw( >= > minimum ) ],
    [ qw( <= < maximum ) ],
  ) {
    my ($op, $e_op, $k) = @$tuple;
    if (exists $self->{$k}) {
      my @new_exclusions = grep { $_ != $self->{ $k } } @exclusions;
      if (@new_exclusions == @exclusions) {
        push @parts, [ $op, "$self->{ $k }" ];
      } else {
        push @parts, [ $e_op, "$self->{ $k }" ];
        @exclusions = @new_exclusions;
      }
    }
  }

  push @parts, map {; [ "!=", "$_" ] } @exclusions;

  return \@parts;
}

=method as_string

  $range->as_string;

This returns a string containing the version requirements in the format
described in L<CPAN::Meta::Spec>. This should only be used for informational
purposes such as error messages and should not be interpreted or used for
comparison (see L</accepts> instead).

=cut

sub as_string {
  my ($self) = @_;

  my @parts = @{ $self->as_struct };

  return $parts[0][1] if @parts == 1 and $parts[0][0] eq '>=';

  return join q{, }, map {; join q{ }, @$_ } @parts;
}

sub _reject_requirements {
  my ($self, $module, $error) = @_;
  Carp::croak("illegal requirements for $module: $error")
}

=method accepts

  my $bool = $range->accepts($version);

Given a version, this method returns true if the version specification
accepts the provided version.  In other words, given:

  '>= 1.00, < 2.00'

We will accept 1.00 and 1.75 but not 0.50 or 2.00.

=cut

sub accepts {
  my ($self, $version) = @_;

  return if defined $self->{minimum} and $version < $self->{minimum};
  return if defined $self->{maximum} and $version > $self->{maximum};
  return if defined $self->{exclusions}
        and grep { $version == $_ } @{ $self->{exclusions} };

  return 1;
}

package
  CPAN::Meta::Requirements::Range::_Exact;

sub _new      { bless { version => $_[1] } => $_[0] }

sub accepts { return $_[0]{version} == $_[1] }

sub _reject_requirements {
  my ($self, $module, $error) = @_;
  Carp::croak("illegal requirements for $module: $error")
}

sub _clone {
  (ref $_[0])->_new( version->new( $_[0]{version} ) )
}

sub with_exact_version {
  my ($self, $version, $module) = @_;
  $module = 'module' unless defined $module;

  return $self->_clone if $self->accepts($version);

  $self->_reject_requirements(
    $module,
    "can't be exactly $version when exact requirement is already $self->{version}",
  );
}

sub with_minimum {
  my ($self, $minimum, $module) = @_;
  $module = 'module' unless defined $module;

  return $self->_clone if $self->{version} >= $minimum;
  $self->_reject_requirements(
    $module,
    "minimum $minimum exceeds exact specification $self->{version}",
  );
}

sub with_maximum {
  my ($self, $maximum, $module) = @_;
  $module = 'module' unless defined $module;

  return $self->_clone if $self->{version} <= $maximum;
  $self->_reject_requirements(
    $module,
    "maximum $maximum below exact specification $self->{version}",
  );
}

sub with_exclusion {
  my ($self, $exclusion, $module) = @_;
  $module = 'module' unless defined $module;

  return $self->_clone unless $exclusion == $self->{version};
  $self->_reject_requirements(
    $module,
    "tried to exclude $exclusion, which is already exactly specified",
  );
}

sub as_string { return "== $_[0]{version}" }

sub as_struct { return [ [ '==', "$_[0]{version}" ] ] }

sub _as_modifiers { return [ [ exact_version => $_[0]{version} ] ] }


1;

# vim: ts=2 sts=2 sw=2 et:
