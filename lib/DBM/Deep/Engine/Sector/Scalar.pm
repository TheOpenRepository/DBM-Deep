package DBM::Deep::Engine::Sector::Scalar;

use 5.006_000;

use strict;
use warnings FATAL => 'all';

use base qw( DBM::Deep::Engine::Sector::Data );

my $STALE_SIZE = 2;

# Please refer to the pack() documentation for further information
my %StP = (
    1 => 'C', # Unsigned char value (no order needed as it's just one byte)
    2 => 'n', # Unsigned short in "network" (big-endian) order
    4 => 'N', # Unsigned long in "network" (big-endian) order
    8 => 'Q', # Usigned quad (no order specified, presumably machine-dependent)
);

sub free {
    my $self = shift;

    my $chain_loc = $self->chain_loc;

    $self->SUPER::free();

    if ( $chain_loc ) {
        $self->engine->_load_sector( $chain_loc )->free;
    }

    return;
}

sub type { $_[0]{engine}->SIG_DATA }
sub _init {
    my $self = shift;

    my $engine = $self->engine;

    unless ( $self->offset ) {
        my $data_section = $self->size - $self->base_size - $engine->byte_size - 1;

        $self->{offset} = $engine->_request_data_sector( $self->size );

        my $data = delete $self->{data};
        my $dlen = length $data;
        my $continue = 1;
        my $curr_offset = $self->offset;
        while ( $continue ) {

            my $next_offset = 0;

            my ($leftover, $this_len, $chunk);
            if ( $dlen > $data_section ) {
                $leftover = 0;
                $this_len = $data_section;
                $chunk = substr( $data, 0, $this_len );

                $dlen -= $data_section;
                $next_offset = $engine->_request_data_sector( $self->size );
                $data = substr( $data, $this_len );
            }
            else {
                $leftover = $data_section - $dlen;
                $this_len = $dlen;
                $chunk = $data;

                $continue = 0;
            }

            $engine->storage->print_at( $curr_offset, $self->type ); # Sector type
            # Skip staleness
            $engine->storage->print_at( $curr_offset + $self->base_size,
                pack( $StP{$engine->byte_size}, $next_offset ),  # Chain loc
                pack( $StP{1}, $this_len ),                      # Data length
                $chunk,                                          # Data to be stored in this sector
                chr(0) x $leftover,                              # Zero-fill the rest
            );

            $curr_offset = $next_offset;
        }

        return;
    }
}

sub data_length {
    my $self = shift;

    my $buffer = $self->engine->storage->read_at(
        $self->offset + $self->base_size + $self->engine->byte_size, 1
    );

    return unpack( $StP{1}, $buffer );
}

sub chain_loc {
    my $self = shift;
    return unpack(
        $StP{$self->engine->byte_size},
        $self->engine->storage->read_at(
            $self->offset + $self->base_size,
            $self->engine->byte_size,
        ),
    );
}

sub data {
    my $self = shift;
#    my ($args) = @_;
#    $args ||= {};

    my $data;
    while ( 1 ) {
        my $chain_loc = $self->chain_loc;

        $data .= $self->engine->storage->read_at(
            $self->offset + $self->base_size + $self->engine->byte_size + 1, $self->data_length,
        );

        last unless $chain_loc;

        $self = $self->engine->_load_sector( $chain_loc );
    }

    return $data;
}

1;
__END__
