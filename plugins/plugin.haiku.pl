# BUCKET PLUGIN

use BucketBase qw/say config Report talking cached_reply sql s/;
my %debug;
my %history;

sub signals {
    return (qw/on_public say do/);
}

sub commands {
    return (
        {
            label     => 'syllables word',
            addressed => 1,
            operator  => 0,
            editable  => 0,
            re        => qr/^how many syllables (?:is|in) (.*)/i,
            callback  => \&report_syllables
        },
        {
            label     => 'syllables line',
            addressed => 1,
            operator  => 0,
            editable  => 0,
            re        => qr/^how many syllables\??$/i,
            callback  => \&report_syllables
        },
    );
}

sub route {
    my ( $package, $sig, $data ) = @_;

    if ( $sig eq 'on_public' and $data->{type} eq 'irc_ctcp_action' ) {
        &add_line( $data, "$data->{who} $data->{msg}" );
    } elsif ( $sig eq 'do' ) {
        &add_line( $data, &config("nick") . " " . $data->{msg} );
    } else {
        &add_line( $data, $data->{msg} );
    }

    &check_haiku($data);

    return 0;
}

sub add_line {
    my ( $bag, $line ) = @_;
    my $chl = $bag->{chl};

    return if ( $bag->{msg} =~ /^how many syllables\??$/i );

    ( $debug{$chl}{count}, $debug{$chl}{line} ) = &count_syllables($line);
    push @{ $history{$chl} }, [ $line, $debug{$chl}{count} ];
}

sub check_haiku {
    my $bag = shift;
    my $chl = $bag->{chl};

    return
      if ( $bag->{addressed}
        or not $bag->{msg}
        or $bag->{msg} =~ /^how many syllables\??$/i );

    if (    @{ $history{$chl} } > 3
        and $history{$chl}[-1][1] == 5
        and $history{$chl}[-2][1] == 7
        and $history{$chl}[-3][1] == 5 )
    {
        my @haiku;
        push @haiku, @{ $history{$chl}[-3] }[0];
        push @haiku, @{ $history{$chl}[-2] }[0];
        push @haiku, @{ $history{$chl}[-1] }[0];
        Report "Haiku found in $chl!";

        if ( &talking($chl) == -1 ) {
            &cached_reply( $chl, $bag->{who}, "", "haiku detected" );
        }

        &sql(
            'insert bucket_facts (fact, verb, tidbit, protected)
                     values (?, ?, ?, 1)',
            [ "Automatic Haiku", "<reply>", join " / ", @haiku, ]
        );
    }

    if ( @{ $history{$chl} } > 3 ) {
        $history{$chl} = [ splice @{ $history{$chl} }, -3 ];
    }
}

sub count_syllables {
    my $line = shift;

    unless ($line) {
        return ( 0, "[empty]" );
    }

    # add spaces to camelCased words
    $line =~ s/([a-z])([A-Z])/$1 $2/g;

    # then ignore case from here on
    $line = lc $line;

    # Deal with dates
    # 1994 - nineteen ninty-four
    # 2008 - two thousand eight or twenty oh eight
    $line =~ s/\b(1[89]|20)(\d\d)\b/$1 $2/g;

    # deal with comma-form numbers
    $line =~ s/,(\d\d\d)/$1/g;

    # Deal with > and < when in words or numbers, i.e. "sagan>all"
    $line =~ s/([a-zA-Z\d ])>([a-zA-Z\d ])/$1 greater than $2/g;
    $line =~ s/([a-zA-Z\d ])<([a-zA-Z\d ])/$1 less than $2/g;

    # Deal with other crap like punctuation
    $line =~ s/\.(com|org|net|info|biz|us)/ dot $1/g;
    $line =~ s/www\./double you double you double you dot /g;
    $line =~ s/[:,\/\*.!?]/ /g;

    # break up at&t to a t & t.  find&replace => find & replace.
    while ( $line =~ /(?:\b|^)(\w+)&(\w+)(?:\b|$)/ ) {
        my ( $first, $last ) = ( $1, $2 );
        if ( length($first) + length($last) < 6 ) {
            my ( $newfirst, $newlast ) = ( $first, $last );
            $newfirst = join " ", split //, $newfirst;
            $newlast  = join " ", split //, $newlast;
            $line =~ s/(?:^|\b)$first&$last(?:\b|$)/$newfirst and $newlast/g;
        } else {
            $line =~ s/(?:^|\b)$first&$last(?:\b|$)/$first and $last/g;
        }
    }
    $line =~ s/&/ and /g;

    # Remove hyphens except when dealing with numbers
    $line =~ s/-(\D|$)/ $1/g;

    my @words = split ' ', $line;
    my $syl = 0;
    my $debug_line;
    foreach my $word (@words) {

        # The main call to syllablecount.
        my ( $count, $debug ) = &syllables($word);

        #print "$word => $debug == $count; ";
        $debug_line .= "$debug ";
        $syl += $count;
    }

    #print "\n$debug_line => $syl\n";

    return ( $syl, $debug_line );
}

# Counts the syllables of a word passed to it.  Strips some formatting.
sub syllables {
    my $word = shift;

    # Check against the cheat sheet dictionary for singular/plurals.
    if ( $config->{sylcheat}{$word} ) {
        return ( $config->{sylcheat}{$word}, "$word (cheat)" );
    }

    if ( $word =~ /s$/ ) {
        my $singular = $word;
        $singular =~ s/'?s$//;
        if ( $config->{sylcheat}{$singular} ) {
            return ( $config->{sylcheat}{$singular},
                "$word (cheat '$singular')" );
        }

        $singular =~ s/se$/s/;
        if ( $config->{sylcheat}{$singular} ) {
            return ( $config->{sylcheat}{$singular},
                "$word (cheat '$singular')" );
        }
    }

    if ( $word =~ /^([a-z])\1*$/ ) {    # Fixed for AAAAAAAAAAAAA and mmmmm
        if ( $word =~ /[aeiou]/ ) {
            return ( 1, "$word (aeiou)" );
        }
        if ( $word =~ /w/ ) {
            return ( 3 * length($word), "$word (w's)" );
        }
        return ( length($word), "$word (single letter)" );
    }

    # Check for non-words, just in case.  This is probably a bit too shotgun-y.
    # Add special cases here or in the cheat sheet, but note that Some
    # punctuation is already stripped.
    if ( $word =~ /^[^a-zA-Z0-9]+$/ ) {
        return ( 0, "$word (non-word)" );
    }

    # Check for likely acronyms (all-consonant string)
    if ( $word =~ /^[bcdfghjklmnpqrstvwxz]+$/ ) {
        return ( length($word) + 2 * $word =~ tr/w/w/, "$word (acronym)" );
    }
    $word =~ s/'//g;

    # Handle numbers
    if ( $word =~ /^[0-9]+$/ ) {
        return ( &numbersyl($word), "$word (number)" );
    }

    # Handle negative numbers as "minus <num>"
    if ( $word =~ /^-[0-9]+$/ ) {
        $word =~ s/^-//;
        return ( 2 + &numbersyl($word), "$word (negative number)" );
    }

    # These are all improvements to ths Syllable library which bring it
    # from the author's estimated 85% accuracy to a much higher accuracy.

    my $modsyl = 0;
    $modsyl++ if ( $word =~ /e[^aeioun]eo/ );
    $modsyl-- if ( $word =~ /e[^aeiou]eo([^s]$|u)/ );
    $modsyl++ if ( $word =~ /[^aeiou]i[rl]e$/ );
    $modsyl-- if ( $word =~ /[^cszaeiou]es$/ );
    $modsyl++ if ( $word =~ /[cs]hes$/ );
    $modsyl++ if ( $word =~ /[^aeiou][aeiouy]ing/ );
    $modsyl-- if ( $word =~ /[aeiou][^aeiou][e]ing/ );
    $modsyl-- if ( $word =~ /(.[^adeiouyt])ed$/ );
    $modsyl-- if ( $word =~ /[agq]ued$/ );
    $modsyl++ if ( $word =~ /(oi|[gbfz])led/ );
    $modsyl++ if ( $word =~ /[aeiou][^aeioub]le$/ );
    $modsyl++ if ( $word =~ /ier$/ );
    $modsyl-- if ( $word =~ /[cp]ally/ );
    $modsyl-- if ( $word =~ /[^aeiou]eful/ );
    $modsyl++ if ( $word =~ /dle$/ );
    $modsyl += 2 if ( $word =~ s/\$//g );

    # force list context, there has to be a prettier way to do this?
    $modsyl -= () = $word =~ m/eau/g;
    $word =~ s/judgement/judgment/g;

    return (
        Lingua::EN::Syllable::syllable($word) + $modsyl,
        $modsyl > 0   ? "$word (+$modsyl)"
        : $modsyl < 0 ? "$word ($modsyl)"
        : $word
    );
}

# This routine pronounces numbers.
# It should correctly handle all integers ranging 1 to 35 digits (hundreds of
# decillions).  Higher than that would be more work and it will have too few
# syllables by about (ln(n)/(3*ln(10))-35/3), and eventually more.

# I'm not commenting it except to say it builds the total up from right to
# left, and that it does not include the optional "and", saying "five hundred
# six" instead of "five hundred and six".

# If you'd like to understand how or why it works in more detail, you'll just
# have to read it very carefully.

sub numbersyl {
    my $num = shift;
    return 1 if ( $num eq "10" or $num eq "12" );
    return 3 if ( $num eq "11" );
    return 2 if ( $num eq "0" );
    return 2 if ( $num eq "00" );

    my $sylcount = 0;
    if ( length $num > 15 ) {
        $sylcount += int( ( length($num) - 13 ) / 3 );
    }
    my @chars = split //, $num;
    if ( @chars == 2 ) {    # "03 == oh three"
        if ( $chars[1] eq "0" ) {
            return 1 + &seven( $chars[0] );
        }
    }
    my $place          = 1;
    my $futuresylcount = 0;
    foreach my $digit ( reverse @chars ) {
        if ($futuresylcount) {
            $sylcount += $futuresylcount;
            $futuresylcount = 0;
        }
        if ( $place == 1 ) {
            $sylcount += &seven($digit);
        }
        if ( $place == 2 ) {
            if ( $digit eq "0" ) {
                $sylcount += 0;
            } elsif ( $digit eq "1" ) {
                $sylcount += 1;
            } else {
                $sylcount += 1 + &seven($digit);
            }
        }
        if ( $place == 3 ) {
            if ( $digit eq "0" ) {
                $sylcount += 0;
            } else {
                $sylcount += 2 + &seven($digit);
            }
        }
        if ( $place == 3 ) {
            $futuresylcount += 2;
            $place = 0;
        }
        $place++;
    }
    return $sylcount;
}

# Very simple routine.  Number of syllables in a single digit, except for 0
# which is a special case in the routines it's used in.
sub seven {
    my $digit = shift;
    if ( $digit eq "7" ) {
        return 2;
    }
    if ( $digit eq "0" ) {
        return 0;
    }
    return 1;
}

sub report_syllables {
    my $bag = shift;

    if ($1) {
        my ( $count, $debug ) = &count_syllables($1);
        &say(
            $bag->{chl} => sprintf "%s: %d syllable%s.  %s",
            $bag->{who}, $count, &s($count), $debug
        );
    } else {
        my $count = $debug{ $bag->{chl} }{count};
        my $line  = $debug{ $bag->{chl} }{line};

        unless ( $count and $line ) {
            &say( $bag->{chl} => "Sorry, $bag->{who}, I have no idea." );
            return;
        }

        &say(
            $bag->{chl} => "$bag->{who}, that was '$line', with $count syllable"
              . &s($count) );
    }
}
