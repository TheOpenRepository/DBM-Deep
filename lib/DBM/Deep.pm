package DBM::Deep;

use 5.006_000;

use strict;
use warnings FATAL => 'all';

our $VERSION = q(1.0014);

use Data::Dumper ();
use Scalar::Util ();

use DBM::Deep::Engine;
use DBM::Deep::File;

use overload
    '""' => sub { overload::StrVal( $_[0] ) },
    fallback => 1;

use constant DEBUG => 0;

##
# Setup constants for users to pass to new()
##
sub TYPE_HASH   () { DBM::Deep::Engine->SIG_HASH  }
sub TYPE_ARRAY  () { DBM::Deep::Engine->SIG_ARRAY }

# This is used in all the children of this class in their TIE<type> methods.
sub _get_args {
    my $proto = shift;

    my $args;
    if (scalar(@_) > 1) {
        if ( @_ % 2 ) {
            $proto->_throw_error( "Odd number of parameters to " . (caller(1))[2] );
        }
        $args = {@_};
    }
    elsif ( ref $_[0] ) {
        unless ( eval { local $SIG{'__DIE__'}; %{$_[0]} || 1 } ) {
            $proto->_throw_error( "Not a hashref in args to " . (caller(1))[2] );
        }
        $args = $_[0];
    }
    else {
        $args = { file => shift };
    }

    return $args;
}

sub new {
    ##
    # Class constructor method for Perl OO interface.
    # Calls tie() and returns blessed reference to tied hash or array,
    # providing a hybrid OO/tie interface.
    ##
    my $class = shift;
    my $args = $class->_get_args( @_ );

    ##
    # Check if we want a tied hash or array.
    ##
    my $self;
    if (defined($args->{type}) && $args->{type} eq TYPE_ARRAY) {
        $class = 'DBM::Deep::Array';
        require DBM::Deep::Array;
        tie @$self, $class, %$args;
    }
    else {
        $class = 'DBM::Deep::Hash';
        require DBM::Deep::Hash;
        tie %$self, $class, %$args;
    }

    return bless $self, $class;
}

# This initializer is called from the various TIE* methods. new() calls tie(),
# which allows for a single point of entry.
sub _init {
    my $class = shift;
    my ($args) = @_;

    # locking implicitly enables autoflush
    if ($args->{locking}) { $args->{autoflush} = 1; }

    # These are the defaults to be optionally overridden below
    my $self = bless {
        type        => TYPE_HASH,
        base_offset => undef,
        staleness   => undef,
        engine      => undef,
    }, $class;

    $args->{engine} = DBM::Deep::Engine->new( { %{$args}, obj => $self } )
        unless exists $args->{engine};

    # Grab the parameters we want to use
    foreach my $param ( keys %$self ) {
        next unless exists $args->{$param};
        $self->{$param} = $args->{$param};
    }

    eval {
      local $SIG{'__DIE__'};

      $self->lock_exclusive;
      $self->_engine->setup_fh( $self );
      $self->unlock;
    }; if ( $@ ) {
      my $e = $@;
      eval { local $SIG{'__DIE__'}; $self->unlock; };
      die $e;
    }

    return $self;
}

sub TIEHASH {
    shift;
    require DBM::Deep::Hash;
    return DBM::Deep::Hash->TIEHASH( @_ );
}

sub TIEARRAY {
    shift;
    require DBM::Deep::Array;
    return DBM::Deep::Array->TIEARRAY( @_ );
}

sub lock_exclusive {
    my $self = shift->_get_self;
    return $self->_engine->lock_exclusive( $self, @_ );
}
*lock = \&lock_exclusive;
sub lock_shared {
    my $self = shift->_get_self;
    return $self->_engine->lock_shared( $self, @_ );
}

sub unlock {
    my $self = shift->_get_self;
    return $self->_engine->unlock( $self, @_ );
}

sub _copy_value {
    my $self = shift->_get_self;
    my ($spot, $value) = @_;

    if ( !ref $value ) {
        ${$spot} = $value;
    }
    else {
        # This assumes hash or array only. This is a bad assumption moving forward.
        # -RobK, 2008-05-27
        my $r = Scalar::Util::reftype( $value );
        my $tied;
        if ( $r eq 'ARRAY' ) {
            $tied = tied(@$value);
        }
        else {
            $tied = tied(%$value);
        }

        if ( eval { local $SIG{__DIE__}; $tied->isa( 'DBM::Deep' ) } ) {
            ${$spot} = $tied->_repr;
            $tied->_copy_node( ${$spot} );
        }
        else {
            if ( $r eq 'ARRAY' ) {
                ${$spot} = [ @{$value} ];
            }
            else {
                ${$spot} = { %{$value} };
            }
        }

        my $c = Scalar::Util::blessed( $value );
        if ( defined $c && !$c->isa( 'DBM::Deep') ) {
            ${$spot} = bless ${$spot}, $c
        }
    }

    return 1;
}

#sub _copy_node {
#    die "Must be implemented in a child class\n";
#}
#
#sub _repr {
#    die "Must be implemented in a child class\n";
#}

sub export {
    ##
    # Recursively export into standard Perl hashes and arrays.
    ##
    my $self = shift->_get_self;

    my $temp = $self->_repr;

    $self->lock_exclusive;
    $self->_copy_node( $temp );
    $self->unlock;

    my $classname = $self->_engine->get_classname( $self );
    if ( defined $classname ) {
      bless $temp, $classname;
    }

    return $temp;
}

sub _check_legality {
    my $self = shift;
    my ($val) = @_;

    my $r = Scalar::Util::reftype( $val );

    return $r if !defined $r || '' eq $r;
    return $r if 'HASH' eq $r;
    return $r if 'ARRAY' eq $r;

    DBM::Deep->_throw_error(
        "Storage of references of type '$r' is not supported."
    );
}

sub import {
    # Perl calls import() on use -- ignore
    return if !ref $_[0];

    my $self = shift->_get_self;
    my ($struct) = @_;

    my $type = $self->_check_legality( $struct );
    if ( !$type ) {
        DBM::Deep->_throw_error( "Cannot import a scalar" );
    }

    if ( substr( $type, 0, 1 ) ne $self->_type ) {
        DBM::Deep->_throw_error(
            "Cannot import " . ('HASH' eq $type ? 'a hash' : 'an array')
            . " into " . ('HASH' eq $type ? 'an array' : 'a hash')
        );
    }

    my %seen;
    my $recurse;
    $recurse = sub {
        my ($db, $val) = @_;

        my $obj = 'HASH' eq Scalar::Util::reftype( $db ) ? tied(%$db) : tied(@$db);
        $obj ||= $db;

        my $r = $self->_check_legality( $val );
        if ( 'HASH' eq $r ) {
            while ( my ($k, $v) = each %$val ) {
                my $r = $self->_check_legality( $v );
                if ( $r ) {
                    my $temp = 'HASH' eq $r ? {} : [];
                    if ( my $c = Scalar::Util::blessed( $v ) ) {
                        bless $temp, $c;
                    }
                    $obj->put( $k, $temp );
                    $recurse->( $temp, $v );
                }
                else {
                    $obj->put( $k, $v );
                }
            }
        }
        elsif ( 'ARRAY' eq $r ) {
            foreach my $k ( 0 .. $#$val ) {
                my $v = $val->[$k];
                my $r = $self->_check_legality( $v );
                if ( $r ) {
                    my $temp = 'HASH' eq $r ? {} : [];
                    if ( my $c = Scalar::Util::blessed( $v ) ) {
                        bless $temp, $c;
                    }
                    $obj->put( $k, $temp );
                    $recurse->( $temp, $v );
                }
                else {
                    $obj->put( $k, $v );
                }
            }
        }
    };
    $recurse->( $self, $struct );

    return 1;
}

#XXX Need to keep track of who has a fh to this file in order to
#XXX close them all prior to optimize on Win32/cygwin
sub optimize {
    ##
    # Rebuild entire database into new file, then move
    # it back on top of original.
    ##
    my $self = shift->_get_self;

#XXX Need to create a new test for this
#    if ($self->_engine->storage->{links} > 1) {
#        $self->_throw_error("Cannot optimize: reference count is greater than 1");
#    }

    #XXX Do we have to lock the tempfile?

    #XXX Should we use tempfile() here instead of a hard-coded name?
    my $temp_filename = $self->_engine->storage->{file} . '.tmp';
    my $db_temp = DBM::Deep->new(
        file => $temp_filename,
        type => $self->_type,

        # Bring over all the parameters that we need to bring over
        ( map { $_ => $self->_engine->$_ } qw(
            byte_size max_buckets data_sector_size num_txns
        )),
    );

    $self->lock_exclusive;
    $self->_engine->clear_cache;
    $self->_copy_node( $db_temp );
    $db_temp->_engine->storage->close;
    undef $db_temp;

    ##
    # Attempt to copy user, group and permissions over to new file
    ##
    $self->_engine->storage->copy_stats( $temp_filename );

    # q.v. perlport for more information on this variable
    if ( $^O eq 'MSWin32' || $^O eq 'cygwin' ) {
        ##
        # Potential race condition when optmizing on Win32 with locking.
        # The Windows filesystem requires that the filehandle be closed
        # before it is overwritten with rename().  This could be redone
        # with a soft copy.
        ##
        $self->unlock;
        $self->_engine->storage->close;
    }

    if (!rename $temp_filename, $self->_engine->storage->{file}) {
        unlink $temp_filename;
        $self->unlock;
        $self->_throw_error("Optimize failed: Cannot copy temp file over original: $!");
    }

    $self->unlock;
    $self->_engine->storage->close;

    $self->_engine->storage->open;
    $self->lock_exclusive;
    $self->_engine->setup_fh( $self );
    $self->unlock;

    return 1;
}

sub clone {
    ##
    # Make copy of object and return
    ##
    my $self = shift->_get_self;

    return DBM::Deep->new(
        type        => $self->_type,
        base_offset => $self->_base_offset,
        staleness   => $self->_staleness,
        engine      => $self->_engine,
    );
}

#XXX Migrate this to the engine, where it really belongs and go through some
# API - stop poking in the innards of someone else..
{
    my %is_legal_filter = map {
        $_ => ~~1,
    } qw(
        store_key store_value
        fetch_key fetch_value
    );

    sub set_filter {
        my $self = shift->_get_self;
        my $type = lc shift;
        my $func = shift;

        if ( $is_legal_filter{$type} ) {
            $self->_engine->storage->{"filter_$type"} = $func;
            return 1;
        }

        return;
    }

    sub filter_store_key   { $_[0]->set_filter( store_key   => $_[1] ); }
    sub filter_store_value { $_[0]->set_filter( store_value => $_[1] ); }
    sub filter_fetch_key   { $_[0]->set_filter( fetch_key   => $_[1] ); }
    sub filter_fetch_value { $_[0]->set_filter( fetch_value => $_[1] ); }
}

sub begin_work {
    my $self = shift->_get_self;
    $self->lock_exclusive;
    my $rv = eval { $self->_engine->begin_work( $self, @_ ) };
    my $e = $@;
    $self->unlock;
    die $e if $e;
    return $rv;
}

sub rollback {
    my $self = shift->_get_self;
    $self->lock_exclusive;
    my $rv = eval { $self->_engine->rollback( $self, @_ ) };
    my $e = $@;
    $self->unlock;
    die $e if $e;
    return $rv;
}

sub commit {
    my $self = shift->_get_self;
    $self->lock_exclusive;
    my $rv = eval { $self->_engine->commit( $self, @_ ) };
    my $e = $@;
    $self->unlock;
    die $e if $e;
    return $rv;
}

##
# Accessor methods
##

sub _engine {
    my $self = $_[0]->_get_self;
    return $self->{engine};
}

sub _type {
    my $self = $_[0]->_get_self;
    return $self->{type};
}

sub _base_offset {
    my $self = $_[0]->_get_self;
    return $self->{base_offset};
}

sub _staleness {
    my $self = $_[0]->_get_self;
    return $self->{staleness};
}

##
# Utility methods
##

sub _throw_error {
    my $n = 0;
    while( 1 ) {
        my @caller = caller( ++$n );
        next if $caller[0] =~ m/^DBM::Deep/;

        die "DBM::Deep: $_[1] at $0 line $caller[2]\n";
    }
}

sub STORE {
    ##
    # Store single hash key/value or array element in database.
    ##
    my $self = shift->_get_self;
    my ($key, $value) = @_;
    warn "STORE($self, '$key', '@{[defined$value?$value:'undef']}')\n" if DEBUG;

    unless ( $self->_engine->storage->is_writable ) {
        $self->_throw_error( 'Cannot write to a readonly filehandle' );
    }

    $self->lock_exclusive;

    # User may be storing a complex value, in which case we do not want it run
    # through the filtering system.
    if ( !ref($value) && $self->_engine->storage->{filter_store_value} ) {
        $value = $self->_engine->storage->{filter_store_value}->( $value );
    }

    my $x = $self->_engine->write_value( $self, $key, $value);

    $self->unlock;

    return 1;
}

sub FETCH {
    ##
    # Fetch single value or element given plain key or array index
    ##
    my $self = shift->_get_self;
    my ($key) = @_;
    warn "FETCH($self, '$key')\n" if DEBUG;

    $self->lock_shared;

    my $result = $self->_engine->read_value( $self, $key);

    $self->unlock;

    # Filters only apply to scalar values, so the ref check is making
    # sure the fetched bucket is a scalar, not a child hash or array.
    return ($result && !ref($result) && $self->_engine->storage->{filter_fetch_value})
        ? $self->_engine->storage->{filter_fetch_value}->($result)
        : $result;
}

sub DELETE {
    ##
    # Delete single key/value pair or element given plain key or array index
    ##
    my $self = shift->_get_self;
    my ($key) = @_;
    warn "DELETE($self, '$key')\n" if DEBUG;

    unless ( $self->_engine->storage->is_writable ) {
        $self->_throw_error( 'Cannot write to a readonly filehandle' );
    }

    $self->lock_exclusive;

    ##
    # Delete bucket
    ##
    my $value = $self->_engine->delete_key( $self, $key);

    if (defined $value && !ref($value) && $self->_engine->storage->{filter_fetch_value}) {
        $value = $self->_engine->storage->{filter_fetch_value}->($value);
    }

    $self->unlock;

    return $value;
}

sub EXISTS {
    ##
    # Check if a single key or element exists given plain key or array index
    ##
    my $self = shift->_get_self;
    my ($key) = @_;
    warn "EXISTS($self, '$key')\n" if DEBUG;

    $self->lock_shared;

    my $result = $self->_engine->key_exists( $self, $key );

    $self->unlock;

    return $result;
}

sub CLEAR {
    ##
    # Clear all keys from hash, or all elements from array.
    ##
    my $self = shift->_get_self;
    warn "CLEAR($self)\n" if DEBUG;

    unless ( $self->_engine->storage->is_writable ) {
        $self->_throw_error( 'Cannot write to a readonly filehandle' );
    }

    $self->lock_exclusive;

    #XXX Rewrite this dreck to do it in the engine as a tight loop vs.
    # iterating over keys - such a WASTE - is this required for transactional
    # clearning?! Surely that can be detected in the engine ...
    if ( $self->_type eq TYPE_HASH ) {
        my $key = $self->first_key;
        while ( $key ) {
            # Retrieve the key before deleting because we depend on next_key
            my $next_key = $self->next_key( $key );
            $self->_engine->delete_key( $self, $key, $key );
            $key = $next_key;
        }
    }
    else {
        my $size = $self->FETCHSIZE;
        for my $key ( 0 .. $size - 1 ) {
            $self->_engine->delete_key( $self, $key, $key );
        }
        $self->STORESIZE( 0 );
    }

    $self->unlock;

    return 1;
}

##
# Public method aliases
##
sub put { (shift)->STORE( @_ ) }
sub store { (shift)->STORE( @_ ) }
sub get { (shift)->FETCH( @_ ) }
sub fetch { (shift)->FETCH( @_ ) }
sub delete { (shift)->DELETE( @_ ) }
sub exists { (shift)->EXISTS( @_ ) }
sub clear { (shift)->CLEAR( @_ ) }

sub _dump_file {shift->_get_self->_engine->_dump_file;}

1;
__END__
