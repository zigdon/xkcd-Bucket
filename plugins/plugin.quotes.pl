# BUCKET PLUGIN

use BucketBase qw/say say_long Log Report config save post/;

my %history;

sub signals {
    return (qw/on_public say do/);
}

sub commands {
    return (
        {
            label     => 'do quote',
            addressed => 1,
            operator  => 1,
            editable  => 0,
            re        => qr/^do quote ([\w\-]+)\W*$/i,
            callback  => \&allow_quote
        },
        {
            label     => 'dont quote',
            addressed => 1,
            operator  => 1,
            editable  => 0,
            re        => qr/^don't quote ([\w\-]+)\W*$/i,
            callback  => \&disallow_quote
        },
        {
            label     => 'list protections',
            addressed => 1,
            operator  => 1,
            editable  => 0,
            re        => qr/^list protected quotes$/i,
            callback  => \&list_protections
        },
        {
            label     => 'remember',
            addressed => 1,
            operator  => 0,
            editable  => 0,
            re        => qr/^remember (\S+) ([^<>]+)$/i,
            callback  => \&quote
        },
    );
}

sub settings {
    return ( history_size => [ i => 30 ],);
}

sub route {
    my ( $package, $sig, $data ) = @_;

    if ( $sig eq 'on_public' ) {
        &save_history($data);
    } elsif ( $sig eq 'say' or $sig eq 'do' ) {
        &save_self_history( $data, $sig );
    }

    return 0;
}

sub save_history {
    my $bag = shift;

    $history{ $bag->{chl} } = [] unless ( exists $history{ $bag->{chl} } );
    push @{ $history{ $bag->{chl} } },
      [ $bag->{who}, $bag->{type}, $bag->{msg} ];

    while ( @{ $history{ $bag->{chl} } } > &config("history_size") ) {
        last unless shift @{ $history{ $bag->{chl} } };
    }
}

sub save_self_history {
    my ( $bag, $type ) = @_;
    push @{ $history{ $bag->{chl} } },
      [
        &config("nick"), ( $type eq 'say' ? 'irc_public' : 'irc_ctcp_action' ),
        $bag->{text}
      ];
}

sub list_protections {
    my $bag = shift;
    my $quoteable = &config("protected_quotes") || {};
    if (keys %$quoteable) {
      &say_long( $bag->{chl} => "$bag->{who}: " . join(", ", sort keys %$quoteable));
    } else {
      &say_long( $bag->{chl} => "$bag->{who}: I'm remembering everything." );
    }
}

sub allow_quote {
    my $bag = shift;
    &make_quotable( $1, 1, $bag );
}

sub disallow_quote {
    my $bag = shift;
    &make_quotable( $1, 0, $bag );
}

sub make_quotable {
    my ( $target, $bit, $bag ) = @_;

    my $quoteable = &config("protected_quotes") || {};
    if ($bit) {
        delete $quoteable->{ lc $target };
    } else {
        $quoteable->{ lc $target } = 1;
    }
    &config( "protected_quotes", $quoteable );
    &say( $bag->{chl} => "Okay, $bag->{who}." );
    &Report(
        "$bag->{who} asked to",
        ( $bit ? "unprotect" : "protect" ),
        "the '$target quotes' factoid."
    );
    &save;
}

sub quote {
    my $bag = shift;
    my ( $target, $re ) = ( $1, $2 );
    if (    &config("protected_quotes")
        and &config("protected_quotes")->{ lc $target } )
    {
        &say( $bag->{chl} =>
              "Sorry, $bag->{who}, you can't use remember for $target quotes."
        );
        return;
    }

    if ( lc $target eq lc $bag->{who} ) {
        &say( $bag->{chl} => "$bag->{who}, please don't quote yourself." );
        return;
    }

    my $match;
    foreach my $line ( reverse @{ $history{ $bag->{chl} } } ) {
        next unless lc $line->[0] eq lc $1;
        next unless $line->[2] =~ /\Q$2/i;

        $match = $line;
        last;
    }

    unless ($match) {
        &say( $bag->{chl} =>
"Sorry, $bag->{who}, I don't remember what $target said about '$re'."
        );
        return;
    }

    my $quote;
    $match->[2] =~ s/^(?:\S+:)? +//;
    if ( $match->[1] eq 'irc_ctcp_action' ) {
        $quote = "* $match->[0] $match->[2]";
    } else {
        $quote = "<$match->[0]> $match->[2]";
    }
    $quote =~ s/\$/\\\$/g;
    &Log("Remembering '$match->[0] quotes' '<reply>' '$quote'");
    &post(
        db  => 'SINGLE',
        SQL => 'select id, tidbit from bucket_facts 
                where fact = ? and verb = "<alias>"',
        PLACEHOLDERS => ["$match->[0] quotes"],
        BAGGAGE      => {
            %$bag,
            msg       => "$match->[0] quotes <reply> $quote",
            orig      => "$match->[0] quotes <reply> $quote",
            addressed => 1,
            fact      => "$match->[0] quotes",
            verb      => "<reply>",
            tidbit    => $quote,
            cmd       => "unalias",
            ack       => "Okay, $bag->{who}, remembering \"$match->[2]\".",
        },
        EVENT => 'db_success'
    );
}
