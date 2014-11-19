use strict;
use warnings;

use CPAN::Meta::Requirements;

use Test::More 0.88;

sub dies_ok (&@) {
  my ($code, $qr, $comment) = @_;

  my $lived = eval { $code->(); 1 };

  if ($lived) {
    fail("$comment: did not die");
  } else {
    like($@, $qr, $comment);
  }
}

{
  my $string_hash = {
    Left   => 10,
    Shared => '>= 2, <= 9, != 7',
    Right  => 18,
  };

  my $req = CPAN::Meta::Requirements->from_string_hash($string_hash);

  is_deeply(
    $req->as_string_hash,
    $string_hash,
    "we can load from a string hash",
  );
}

{
  my $string_hash = {
    Left   => 10,
    Shared => '= 2',
    Right  => 18,
  };

  dies_ok { CPAN::Meta::Requirements->from_string_hash($string_hash) }
    qr/Can't convert/,
    "we die when we can't understand a version spec";
}

{
  my $undef_hash = { Undef => undef };
  my $z_hash = { ZeroLength => '' };

  my $warning;
  local $SIG{__WARN__} = sub { $warning = join("\n",@_) };

  my $req = CPAN::Meta::Requirements->from_string_hash($undef_hash);
  like ($warning, qr/Undefined requirement.*treated as '0'/, "undef requirement warns");
  $req->add_string_requirement(%$z_hash);
  like ($warning, qr/Undefined requirement.*treated as '0'/, "'' requirement warns");

  is_deeply(
    $req->as_string_hash,
    { map { ($_ => 0) } keys(%$undef_hash), keys(%$z_hash) },
    "undef/'' requirements treated as '0'",
  );
}

{
  my $string_hash = {
    Left   => 10,
    Shared => v50.44.60,
    Right  => 18,
  };

  my $warning;
  local $SIG{__WARN__} = sub { $warning = join("\n",@_) };

  my $req = CPAN::Meta::Requirements->from_string_hash($string_hash);

  ok(
    $req->accepts_module(Shared => 'v50.44.60'),
    "vstring treated as if string",
  );
}

done_testing;
