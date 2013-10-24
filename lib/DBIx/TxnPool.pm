package DBIx::TxnPool;

use strict;
use warnings;
use Exporter 5.57 qw( import );

use Try::Tiny;

our $VERSION = 0.05;
our @EXPORT = qw( txn_item txn_post_item txn_commit );

sub new {
    my ( $class, %args ) = @_;

    die( __PACKAGE__ . ": the dbh should be defined" )
      unless $args{dbh};

    $args{size}                   ||= 100;
    $args{max_repeated_deadlocks} ||= 5;
    $args{pool}                   = [];
    $args{amount_deadlocks}       = 0;

    bless \%args, ref $class || $class;
}

sub DESTROY {
    $_[0]->finish;
}

sub txn_item (&@) {
    __PACKAGE__->new( %{ __make_chain( 'item_callback', @_ ) } );
}

sub txn_post_item (&@) {
    __make_chain( 'post_item_callback', @_ );
}

sub txn_commit (&@) {
    __make_chain( 'commit_callback', @_ );
}

sub __make_chain {
    my $cb_name = shift;
    my $cb_func = shift;
    my $ret;

    ( $ret = ref $_[0] eq 'HASH' ? $_[0] : { @_ } )->{ $cb_name } = $cb_func;
    $ret;
}

sub dbh { $_[0]->{dbh} }

sub add {
    my ( $self, $data ) = @_;

    $self->{repeated_deadlocks} = 0;
    try {
        push @{ $self->{pool} }, $data;

        $self->start_txn;

        local $_ = $data;
        $self->{item_callback}->( $self, $data );
    }
    catch {
        $self->rollback_txn;

        /deadlock/io
        ?
            ( $self->{amount_deadlocks}++, $self->repeat_again )
        :
            die( __PACKAGE__ . ": error in item callback ($_)" );
    };

    $self->finish
      if ( @{ $self->{pool} } >= $self->{size} );
}

sub repeat_again {
    my $self = shift;

    $self->start_txn;
    select( undef, undef, undef, 0.1 * ++$self->{repeated_deadlocks} );

    try {
        foreach my $data ( @{ $self->{pool} } ) {
            local $_ = $data;
            $self->{item_callback}->( $self, $data );
        }
    }
    catch {
        $self->rollback_txn;

        /deadlock/io
        ?
            (
                $self->{amount_deadlocks}++, $self->{repeated_deadlocks} >= $self->{max_repeated_deadlocks}
                ?
                    die( __PACKAGE__ . ": limit of deadlock resolvings" )
                :
                    $self->repeat_again
            )
        :
            die( __PACKAGE__ . ": error in item callback ($_)" );
    };
}

sub finish {
    my $self = shift;

    $self->{repeated_deadlocks} = 0;
    $self->commit_txn;

    if ( exists $self->{post_item_callback} ) {
        foreach my $data ( @{ $self->{pool} } ) {
            local $_ = $data;
            $self->{post_item_callback}->( $self, $data );
        }
    }

    $self->{pool} = [];
}

sub start_txn {
    my $self = shift;

    if ( ! $self->{in_txn} ) {
        $self->{dbh}->begin_work or die $self->{dbh}->errstr;
        $self->{in_txn} = 1;
    }
}

sub rollback_txn {
    my $self = shift;

    if ( $self->{in_txn} ) {
        $self->{dbh}->rollback or die $self->{dbh}->errstr;
        $self->{in_txn} = undef;
    }
}

sub commit_txn {
    my $self = shift;

    if ( $self->{in_txn} ) {
        $self->{dbh}->commit or die $self->{dbh}->errstr;
        $self->{commit_callback}->( $self )
          if exists $self->{commit_callback};
        $self->{in_txn} = undef;
    }
}

sub amount_deadlocks { $_[0]->{amount_deadlocks} }

1;

__END__

=pod

=head1 NAME

DBIx::TxnPool - The helper for making SQL insert/delete/update statements through a transaction method with a deadlock solution

=head1 SYNOPSIS

    use DBIx::TxnPool;

    my $pool = txn_item {
        # $_ consists the one item
        # code has dbh & sth handle statements
        # It's executed for every item inside one transaction maximum of size 'size'
        # this code may be recalled if deadlocks will occur
    }
    txn_post_item {
        # $_ consists the one item
        # code executed for every item after sucessfully commited transaction
    } dbh => $dbh, size => 100;

    foreach my $i ( 0 .. 1000 ) {
        $pool->add( { i => $i, value => 'test' . $i } );
    }

    $pool->finish;

=head1 DESCRIPTION

Sometimes i need in module which helps to me to wrap some SQL manipulation
statements to one transaction. If you make alone insert/delete/update statement
in the InnoDB engine, MySQL server for example does fsync (data flushing to disk) after
each statements. It can be very slowly if you update 100,000 and more rows for
example. The better way to wrap some insert/delete/update statements in one
transaction for example. But there can be other problem - deadlocks. If a
deadlock occur the DBI's module can throws exceptions and ideal way to repeat SQL
statements again. This module helps to make it. It has a pool inside for data (FIFO
buffer) and calls your callbacks for each pushed item. When you feed a module by
your data, it wraps data in one transaction up to the maximum defined size or up to
the finish method. If deadlock occurs it repeats your callbacks for every item again.
You can define a second callback which will be executed for every item after
wrapped transaction. For example there can be non-SQL statements, for example a
deleting files, cleanups and etc.

=head1 CONSTRUCTOR

The object DBIx::TxnPool created by txn_item subroutines:

    my $pool = txn_item {
        my ( $pool, $item ) = @_;
        # $_ consists the item too

        # It's executed for every item inside one transaction maximum of size 'size'
        # this code may be recalled if deadlocks will occur

        # code has dbh & sth handle statements
        $pool->dbh->do("UPDATE ...");
        $pool->dbh->do("INSERT ...");
        $pool->dbh->do("DELETE...");
    }
    txn_post_item {
        my ( $pool, $item ) = @_;
        # $_ consists the item too
        # code executed for every item after sucessfully commited transaction
        unlink('some_file);
    }
    txn_commit {
        my $pool = shift;
        # we log here each transaction for example
        log( 'The commit was here...' );
    } dbh => $dbh, size => 100;

Or other way:

    my $pool = txn_item {
        # $_ consists the one item
        # code has dbh & sth handle statements
        # It's executed for every item inside one transaction maximum of size 'size'
        # this code may be recalled if deadlocks will occur
    } dbh => $dbh, size => 100;

=head2 Shortcuts:

The C<txn_item> should be first. Other sortcuts can follow in any order.
Parameters should be the last.

=over

=item txn_item B<(Required)>

The transaction's item callback. Here should be SQL statements and code should
be safe for repeating (when a deadlock occurs). The C<$_> consists a current item.
You can modify it if one is hashref for example. Passing arguments will be
I<DBIx::TxnPool> object and I<current item> respectively.

=item txn_post_item B<(Optional)>

The post transaction item callback. This code will be executed once for each
item (defined in C<$_>). It is located outside of the transaction. And it will
be called if whole transaction was succaessful. Passing arguments will be
I<DBIx::TxnPool> object and I<current item> respectively.

=item txn_commit B<(Optional)>

This callback will be called after each SQL commit statement. Here you can put
code for logging for example. The first argument will be I<DBIx::TxnPool> object

=back

=head2 Parameters:

=over

=item dbh B<(Required)>

The dbh to be needed for begin_work & commit method (wrap in a transaction).

=item size B<(Optional)>

The size of pool when a commit method will be called when feeding reaches the same size.

=item max_repeated_deadlocks B<(Optional)>

The limit of consecutive deadlocks. The default is 5. After limit to be reached
the L</add> throws exception.

=back

=head1 METHODS

=over

=item add

You can add item of data to the pool. This method makes a wrap to transaction.
It can finish transaction if pool reaches up to size or can repeat a whole
transaction again if deadlock exception was thrown. The size of transaction may
be less than your defined size!

=item dbh

The accessor of C<dbh>. It's readonly.

=item finish

It makes a final transaction if pool is not empty.

=item amount_deadlocks

The amount of deadlocks (repeated transactions)

=back

=head1 AUTHOR

This module has been written by Perlover <perlover@perlover.com>

=head1 LICENSE

This module is free software and is published under the same terms as Perl
itself.

=head1 SEE ALSO

L<DBI>, L<Deadlock Detection and Rollback|http://dev.mysql.com/doc/refman/5.5/en/innodb-deadlock-detection.html>

=head1 TODO

=over

=item A supporting DBIx::Connector object instead DBI

=item To add other callbacks in future.

=back

=cut
