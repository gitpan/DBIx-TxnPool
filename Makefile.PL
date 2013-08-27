use strict;
use warnings;

use inc::Module::Install;

name 'DBIx-TxnPool';
abstract 'The pool for making SQL insert/delete/updates more quickly by transaction method';

author 'Perlover <perlover@perlover.com>';
version_from 'lib/DBIx/TxnPool.pm';
auto_set_repository;
author_tests('xt');
license 'perl';

WriteAll();

package MY;

sub distdir {
    my $inherited = shift->SUPER::distdir(@_);
    $inherited =~ s/^(create_distdir\s.*)/$& README/m;
    $inherited .= "README : lib/DBIx/TxnPool.pm\n\tperldoc -t lib/DBIx/TxnPool.pm > README\n";
    return $inherited;
}
