use v5.10;
use strict;
use warnings;
package CPAN::Meta::Requirements;
# ABSTRACT: a set of version requirements for a CPAN dist

our $VERSION = '2.146';

use CPAN::Meta::Requirements::Range;

=head1 SYNOPSIS

  use CPAN::Meta::Requirements;

  my $build_requires = CPAN::Meta::Requirements->new;

  $build_requires->add_minimum('Library::Foo' => 1.208);

  $build_requires->add_minimum('Library::Foo' => 2.602);

  $build_requires->add_minimum('Module::Bar'  => 'v1.2.3');

  $METAyml->{build_requires} = $build_requires->as_string_hash;

=head1 DESCRIPTION

A CPAN::Meta::Requirements object models a set of version constraints like
those specified in the F<META.yml> or F<META.json> files in CPAN distributions,
and as defined by L<CPAN::Meta::Spec>.
It can be built up by adding more and more constraints, and it will reduce them
to the simplest representation.

Logically impossible constraints will be identified immediately by thrown
exceptions.

=cut

use Carp ();

=method new

  my $req = CPAN::Meta::Requirements->new;

This returns a new CPAN::Meta::Requirements object.  It takes an optional
hash reference argument.  Currently, only one key is supported:

=for :list
* C<bad_version_hook> -- if provided, when a version cannot be parsed into
  a version object, this code reference will be called with the invalid
  version string as first argument, and the module name as second
  argument.  It must return a valid version object.

All other keys are ignored.

=cut

my @valid_options = qw( bad_version_hook );

sub new {
  my ($class, $options) = @_;
  $options ||= {};
  Carp::croak "Argument to $class\->new() must be a hash reference"
    unless ref $options eq 'HASH';
  my %self = map {; $_ => $options->{$_}} @valid_options;

  return bless \%self => $class;
}

=method add_minimum

  $req->add_minimum( $module => $version );

This adds a new minimum version requirement.  If the new requirement is
redundant to the existing specification, this has no effect.

Minimum requirements are inclusive.  C<$version> is required, along with any
greater version number.

This method returns the requirements object.

=method add_maximum

  $req->add_maximum( $module => $version );

This adds a new maximum version requirement.  If the new requirement is
redundant to the existing specification, this has no effect.

Maximum requirements are inclusive.  No version strictly greater than the given
version is allowed.

This method returns the requirements object.

=method add_exclusion

  $req->add_exclusion( $module => $version );

This adds a new excluded version.  For example, you might use these three
method calls:

  $req->add_minimum( $module => '1.00' );
  $req->add_maximum( $module => '1.82' );

  $req->add_exclusion( $module => '1.75' );

Any version between 1.00 and 1.82 inclusive would be acceptable, except for
1.75.

This method returns the requirements object.

=method exact_version

  $req->exact_version( $module => $version );

This sets the version required for the given module to I<exactly> the given
version.  No other version would be considered acceptable.

This method returns the requirements object.

=cut

BEGIN {
  for my $type (qw(maximum exclusion exact_version)) {
    my $method = "with_$type";
    my $to_add = $type eq 'exact_version' ? $type : "add_$type";

    my $code = sub {
      my ($self, $name, $version) = @_;

      $self->__modify_entry_for($name, $method, $version);

      return $self;
    };

    no strict 'refs';
    *$to_add = $code;
  }
}

# add_minimum is optimized compared to generated subs above because
# it is called frequently and with "0" or equivalent input
sub add_minimum {
  my ($self, $name, $version) = @_;

  # stringify $version so that version->new("0.00")->stringify ne "0"
  # which preserves the user's choice of "0.00" as the requirement
  if (not defined $version or "$version" eq '0') {
    return $self if $self->__entry_for($name);
    Carp::croak("can't add new requirements to finalized requirements")
      if $self->is_finalized;

    $self->{requirements}{ $name } =
      CPAN::Meta::Requirements::Range->with_minimum('0', $name);
  }
  else {
    $self->__modify_entry_for($name, 'with_minimum', $version);
  }
  return $self;
}

=method version_range_for_module

  $req->version_range_for_module( $another_req_object );

=cut

sub version_range_for_module {
  my ($self, $module) = @_;
  return $self->{requirements}{$module};
}

=method add_requirements

  $req->add_requirements( $another_req_object );

This method adds all the requirements in the given CPAN::Meta::Requirements
object to the requirements object on which it was called.  If there are any
conflicts, an exception is thrown.

This method returns the requirements object.

=cut

sub add_requirements {
  my ($self, $req) = @_;

  for my $module ($req->required_modules) {
    my $new_range = $req->version_range_for_module($module);
    $self->__modify_entry_for($module, 'with_range', $new_range);
  }

  return $self;
}

=method accepts_module

  my $bool = $req->accepts_module($module => $version);

Given an module and version, this method returns true if the version
specification for the module accepts the provided version.  In other words,
given:

  Module => '>= 1.00, < 2.00'

We will accept 1.00 and 1.75 but not 0.50 or 2.00.

For modules that do not appear in the requirements, this method will return
true.

=cut

sub accepts_module {
  my ($self, $module, $version) = @_;

  return 1 unless my $range = $self->__entry_for($module);
  return $range->accepts($version);
}

=method clear_requirement

  $req->clear_requirement( $module );

This removes the requirement for a given module from the object.

This method returns the requirements object.

=cut

sub clear_requirement {
  my ($self, $module) = @_;

  return $self unless $self->__entry_for($module);

  Carp::croak("can't clear requirements on finalized requirements")
    if $self->is_finalized;

  delete $self->{requirements}{ $module };

  return $self;
}

=method requirements_for_module

  $req->requirements_for_module( $module );

This returns a string containing the version requirements for a given module in
the format described in L<CPAN::Meta::Spec> or undef if the given module has no
requirements. This should only be used for informational purposes such as error
messages and should not be interpreted or used for comparison (see
L</accepts_module> instead).

=cut

sub requirements_for_module {
  my ($self, $module) = @_;
  my $entry = $self->__entry_for($module);
  return unless $entry;
  return $entry->as_string;
}

=method structured_requirements_for_module

  $req->structured_requirements_for_module( $module );

This returns a data structure containing the version requirements for a given
module or undef if the given module has no requirements.  This should
not be used for version checks (see L</accepts_module> instead).

Added in version 2.134.

=cut

sub structured_requirements_for_module {
  my ($self, $module) = @_;
  my $entry = $self->__entry_for($module);
  return unless $entry;
  return $entry->as_struct;
}

=method required_modules

This method returns a list of all the modules for which requirements have been
specified.

=cut

sub required_modules { keys %{ $_[0]{requirements} } }

=method clone

  $req->clone;

This method returns a clone of the invocant.  The clone and the original object
can then be changed independent of one another.

=cut

sub clone {
  my ($self) = @_;
  my $new = (ref $self)->new;

  return $new->add_requirements($self);
}

sub __entry_for     { $_[0]{requirements}{ $_[1] } }

sub __modify_entry_for {
  my ($self, $name, $method, $version) = @_;

  my $fin = $self->is_finalized;
  my $old = $self->__entry_for($name);

  Carp::croak("can't add new requirements to finalized requirements")
    if $fin and not $old;

  my $new = ($old || 'CPAN::Meta::Requirements::Range')
          ->$method($version, $name, $self->{bad_version_hook});

  Carp::croak("can't modify finalized requirements")
    if $fin and $old->as_string ne $new->as_string;

  $self->{requirements}{ $name } = $new;
}

=method is_simple

This method returns true if and only if all requirements are inclusive minimums
-- that is, if their string expression is just the version number.

=cut

sub is_simple {
  my ($self) = @_;
  for my $module ($self->required_modules) {
    # XXX: This is a complete hack, but also entirely correct.
    return if not $self->__entry_for($module)->is_simple;
  }

  return 1;
}

=method is_finalized

This method returns true if the requirements have been finalized by having the
C<finalize> method called on them.

=cut

sub is_finalized { $_[0]{finalized} }

=method finalize

This method marks the requirements finalized.  Subsequent attempts to change
the requirements will be fatal, I<if> they would result in a change.  If they
would not alter the requirements, they have no effect.

If a finalized set of requirements is cloned, the cloned requirements are not
also finalized.

=cut

sub finalize { $_[0]{finalized} = 1 }

=method as_string_hash

This returns a reference to a hash describing the requirements using the
strings in the L<CPAN::Meta::Spec> specification.

For example after the following program:

  my $req = CPAN::Meta::Requirements->new;

  $req->add_minimum('CPAN::Meta::Requirements' => 0.102);

  $req->add_minimum('Library::Foo' => 1.208);

  $req->add_maximum('Library::Foo' => 2.602);

  $req->add_minimum('Module::Bar'  => 'v1.2.3');

  $req->add_exclusion('Module::Bar'  => 'v1.2.8');

  $req->exact_version('Xyzzy'  => '6.01');

  my $hashref = $req->as_string_hash;

C<$hashref> would contain:

  {
    'CPAN::Meta::Requirements' => '0.102',
    'Library::Foo' => '>= 1.208, <= 2.206',
    'Module::Bar'  => '>= v1.2.3, != v1.2.8',
    'Xyzzy'        => '== 6.01',
  }

=cut

sub as_string_hash {
  my ($self) = @_;

  my %hash = map {; $_ => $self->{requirements}{$_}->as_string }
             $self->required_modules;

  return \%hash;
}

=method add_string_requirement

  $req->add_string_requirement('Library::Foo' => '>= 1.208, <= 2.206');
  $req->add_string_requirement('Library::Foo' => v1.208);

This method parses the passed in string and adds the appropriate requirement
for the given module.  A version can be a Perl "v-string".  It understands
version ranges as described in the L<CPAN::Meta::Spec/Version Ranges>. For
example:

=over 4

=item 1.3

=item >= 1.3

=item <= 1.3

=item == 1.3

=item != 1.3

=item > 1.3

=item < 1.3

=item >= 1.3, != 1.5, <= 2.0

A version number without an operator is equivalent to specifying a minimum
(C<E<gt>=>).  Extra whitespace is allowed.

=back

=cut

sub add_string_requirement {
  my ($self, $module, $req) = @_;

  $self->__modify_entry_for($module, 'with_string_requirement', $req);
}

=method from_string_hash

  my $req = CPAN::Meta::Requirements->from_string_hash( \%hash );
  my $req = CPAN::Meta::Requirements->from_string_hash( \%hash, \%opts );

This is an alternate constructor for a CPAN::Meta::Requirements
object. It takes a hash of module names and version requirement
strings and returns a new CPAN::Meta::Requirements object. As with
add_string_requirement, a version can be a Perl "v-string". Optionally,
you can supply a hash-reference of options, exactly as with the L</new>
method.

=cut

sub from_string_hash {
  my ($class, $hash, $options) = @_;

  my $self = $class->new($options);

  for my $module (keys %$hash) {
    my $req = $hash->{$module};
    $self->add_string_requirement($module, $req);
  }

  return $self;
}

1;
# vim: ts=2 sts=2 sw=2 et:
