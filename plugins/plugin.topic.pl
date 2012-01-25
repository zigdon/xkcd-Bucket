# BUCKET PLUGIN

use BucketBase qw/say do Log yield/;

my %topics;

sub signals {
    return (qw/jointopic on_topic/);
}

sub commands {

    # label, addressed, operator, editable, re, callback
    return (
        {
            label     => 'restore topic',
            addressed => 1,
            operator  => 0,
            editable  => 0,
            re        => qr/^restore topic$/i,
            callback  => \&restore_nonop
        },
        {
            label     => 'restore topic',
            addressed => 1,
            operator  => 1,
            editable  => 0,
            re        => qr/^restore topic(?: (#\S+))/i,
            callback  => \&restore_op
        },
    );
}

sub route {
    my ( $package, $sig, $data ) = @_;

    &update_topic($data);

    return 0;
}

sub update_topic {
    my $data = shift;
    Log "Topic in $data->{chl}: '$data->{topic}'";
    $topics{ $data->{chl} }{old} = $topics{ $data->{chl} }{cur};
    $topics{ $data->{chl} }{cur} = $data->{topic};
}

sub restore_nonop {
    my ($bag) = @_;

    return &restore_topic( $bag, $bag->{chl}, $bag->{chl} );
}

sub restore_op {
    my ($bag) = @_;

    return &restore_topic( $bag, $bag->{chl}, $1 );
}

sub restore_topic {
    my ( $bag, $chl, $target ) = @_;

    unless ( $topics{$target} ) {
        &say( $chl =>
              "Sorry, $bag->{who}, I don't know what was the earlier topic!" );
        return;
    }
    Log "$bag->{who} restored topic in $target: $topics{$target}{old}";
    &say( $chl => "Okay, $bag->{who}." );
    &yield( topic => $target => $topics{$target}{old} );
}
