use strict;
use warnings;

use inc::Module::Install;

name 'DBIx-TxnPool';
abstract 'The helper for making SQL insert/delete/update statements through a transaction method with a deadlock solution';

author 'Perlover <perlover@perlover.com>';
license 'perl';
version_from 'lib/DBIx/TxnPool.pm';

requires 'Try::Tiny';

auto_set_repository;
author_tests('xt');

WriteAll();

package MY;

sub distdir {
    my $inherited = shift->SUPER::distdir(@_);
    $inherited =~ s/^(create_distdir\s.*)/$& README/m;
    $inherited .= "README : lib/DBIx/TxnPool.pm\n\tperldoc -t lib/DBIx/TxnPool.pm > README\n";
    return $inherited;
}
