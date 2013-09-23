#!/usr/bin/perl -w

use strict;
use POE;
use POE::Component::IRC;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::NickServID;
use POE::Component::IRC::Plugin::Connector;
use YAML qw/LoadFile DumpFile/;
use Data::Dumper;
$Data::Dumper::Indent = 1;

use constant {
    DEBUG           => 0,
    RE              => 0,
    CHANNEL         => 1,
    ACTION          => 2,
    TIMEOUT         => 3,
    MESSAGE         => 4,
    COMPILED        => 5,
    CHANCE          => 6,
    RANGE           => 7,
    CONTINUE        => 8,
    LOG_PM          => 0,
    ECHO_PUPPETTING => 0,
    SPAM_TOLERANCE  => 5,
};

$|++;

### IRC portion
my $channel = DEBUG ? "#debugchan" : "#controlchan";
my $nick    = DEBUG ? "debugnick" : "realnick";
my $pass    = "sekret";
my ($irc)   = POE::Component::IRC::State->spawn();
my $configfile = "/path/to/config/billygoat.yml";
my $config     = LoadFile($configfile);
my %topics     = ( $channel => 1 );
my %stopword;
my $last_timer;
my $last_expire;
my %kicks;
my %spam_counter;
my %mode_set;
my @banlist;

# set up defaults
$config->{kick_msg} ||= "kicked";
$config->{action}   ||= "ko";
$config->{channels} ||= "*";

&calculate_re;

$irc->plugin_add( 'NickServID',
    POE::Component::IRC::Plugin::NickServID->new( Password => $pass ) );

POE::Session->create(
    inline_states => {
        _start          => \&irc_start,
        irc_001         => \&irc_on_connect,
        irc_public      => \&irc_on_public,
        irc_ctcp_action => \&irc_on_public,
        irc_msg         => \&irc_on_msg,
        irc_notice      => \&irc_on_notice,
        irc_topic       => \&irc_on_topic,
        irc_332         => \&irc_on_jointopic,
        irc_331         => \&irc_on_jointopic,
        irc_367         => \&irc_on_banlist,
        irc_chan_mode   => \&irc_on_chanmode,
        irc_kick        => \&irc_on_kick,
        irc_join        => \&irc_on_join,

        # irc_352         => \&event_dump, # who replies
        _default => sub {
            return unless DEBUG;
            return if $_[ARG0] eq 'irc_ping';
            &event_dump(@_);
            0;
        },
    },
);

POE::Kernel->run;

sub Log {
    print scalar localtime, " - @_\n";
}

sub event_dump {
    print "event: $_[ARG0]... ";
    foreach ( ARG1, ARG2, ARG3 ) {
        if ( ref $_[$_] eq 'ARRAY' ) {
            print "[@{$_[$_]}] ";
        } elsif ( ref $_[$_] ) {
            print "(", ref $_[$_], ") ";
        } elsif ( defined $_[$_] ) {
            print "$_[$_] ";
        } else {
            print ". ";
        }
    }
    print "\n";
}

sub irc_start {
    $irc->yield( register => 'all' );
    $_[HEAP]->{connector} = POE::Component::IRC::Plugin::Connector->new();
    $irc->plugin_add( Connector => $_[HEAP]->{connector} );

    $irc->yield(
        connect => {
            Nick     => $nick,
            Username => $nick,
            Ircname  => "BotBot, maintained by someone",
            Server   => "irc.foonetic.net",
        }
    );
}

sub irc_on_banlist {
    my ( $chan, $ban, $who, $when ) = split ' ', $_[ARG1];
    push @banlist, { chan => $chan, ban => $ban, who => $who, when => $when };
    if ( $who eq $nick ) {
        $irc->delay( [ mode => $chan, "-b", $ban ], 30 );
    }
}

sub irc_on_chanmode {
    my ($who) = split /!/, $_[ARG0];
    my ( $chan, $mode, $mask ) = @_[ ARG1, ARG2, ARG3 ];
    if ( $mode eq '+b' ) {
        push @banlist,
          { chan => $chan, ban => $mask, who => $who, when => time };
    } elsif ( $mode eq '-b' ) {
        @banlist = grep { $_->{ban} ne $mask } @banlist;
    }
}

sub irc_on_join {
    my ( $who, $mask ) = split /!/, $_[ARG0];
    my $chl = $_[ARG1];

    if ( $kicks{$chl}{$who} and time - $kicks{$chl}{$who} <= 1 ) {
        &ban( $chl, "*!$mask", 60 );
        &kick( $chl, $who,
            "Turn off your autojoin. Or type more slowly.  *mutter*" );
        $irc->yield( privmsg => $channel =>
              "$who autojoined $chl after being kicked.  Undoing." );
    }

    delete $kicks{$chl}{$who};

}

sub irc_on_kick {
    my ($kicker) = split /!/, $_[ARG0];
    my $chl      = $_[ARG1];
    my $kickee   = $_[ARG2];
    my $desc     = $_[ARG3];

    Log "$kicker kicked $kickee from $chl";

    # clean up the records of anything older than one second
    foreach my $c ( keys %kicks ) {
        foreach my $n ( keys %{ $kicks{$c} } ) {
            delete $kicks{$c}{$n} if $kicks{$c}{$n} < time - 1;
        }
    }

    $kicks{$chl}{$kickee} = time;
}

sub irc_on_jointopic {
    my ( $chl, $topic ) = @{ $_[ARG2] }[ 0, 1 ];
    $topic =~ s/ ARRAY\(0x\w+\)$//;

    Log "Topic in /$chl/: '$topic'";
    $topics{$chl} = $topic;
}

sub irc_on_topic {
    my ( $who, $chl, $topic ) = ( $_[ARG0], $_[ARG1], $_[ARG2] );
    $who =~ s/!.*//;

    Log "$who set topic in $chl: $topic";
    unless ( $topics{$chl} ) {
        $topics{$chl} = $topic;
        return;
    }

    Log "$who changed the topic in $chl:";
    Log "  Old topic: $topics{$chl}";
    Log "  New topic: $topic";

    if (
            $who ne $nick
        and $topics{$chl} =~ /\|/
        and ( length $topic < 0.5 * length $topics{$chl}
            or $topic !~ /\|.*\|/ )
      )
    {
        my $info = $irc->nick_info($who);
        Log "$who changed the topic in $chl badly.  Undoing.";
        $irc->yield( privmsg => $channel =>
              "$who changed the topic in $chl badly.  Undoing." );

        &ban( $chl, $info->{Userhost}, 300 );
        &kick( $chl, $who, "Leave the topic alone.  *mutter*" );
        $irc->yield( mode => $chl, "+t" );
        $irc->delay( [ mode => $chl, "-t" ], 300 );

        if ( exists $topics{$chl} ) {
            Log "Restoring topic to $topics{$chl}";

            $irc->yield( topic => $chl => $topics{$chl} );
        }
    }

    $topics{$chl} = $topic;
}

sub irc_on_notice {
    my ($who) = split /!/, $_[ARG0];
    my $msg = $_[ARG2];

    Log("Notice from $who: $msg");

    if (    $who eq 'NickServ'
        and $msg =~
        /now identified for|Password accepted|(?:isn't|is not a) registered/ )
    {
        $irc->yield( mode => $nick => "-x+B" );
        $irc->yield( join => $channel );
        unless (DEBUG) {
            Log("Autojoining channels");
            foreach ( keys %{ $config->{autojoin} } ) {
                $irc->yield( join => $_ );
                Log("... $_");
            }
        }
    }
}

sub echo {
    my ( $who, $chl, $msg ) = @_;

    if ( lc $chl ne lc $channel ) {
        $irc->yield( privmsg => $channel => "(PM $who:) $msg" );
    }
    $irc->yield( privmsg => $chl => $msg );

}

sub irc_on_msg {
    my ($who) = split /!/, $_[ARG0];
    my $chl = $_[ARG1];
    $chl = $chl->[0];
    my $msg = $_[ARG2];

    Log("private: $who ($chl): $msg") if LOG_PM;
    if (   $irc->is_channel_operator( $channel, $who )
        or $irc->is_channel_owner( $channel, $who )
        or $irc->is_channel_admin( $channel, $who ) )
    {    # only ops can give actual commands
        if ( substr( $chl, 0, 1 ) eq '#' ) {
            return unless $msg =~ s/^\s*$nick[:,]\s*//i;
        } else {
            $chl = $who;
        }
        my ( $cmd, $arg ) = split ' ', $msg, 2;

        if ( $cmd eq 'add' ) {

            # parse the options
            my %args = &parse_add_args($arg);
            $args{channel} ||= $config->{channels};
            $args{action}  ||= $config->{action};
            $args{timeout} ||= 0;
            $args{message} ||= $config->{kick_msg};
            $args{chance}  ||= 100;
            $arg = $args{re};

            # try to compile the remainder as a RE
            $arg =~ s/^\s+|\s$//g;
            eval { qr/$arg/ };
            if ($@) {
                &irc->yield( privmsg => $chl => "Failed to compile: $@" );
            } else {

                # RE, chls, action, args
                push @{ $config->{re_list} },
                  [
                    $arg,
                    @args{
                        qw/channel action timeout message undef chance range continue /
                      }
                  ];
                &calculate_re;
                &save;
                &echo( $who, $chl, "Added '$arg'" );
            }
        } elsif ( $cmd eq 'edit' ) {

            # get the rule number
            my $number;
            if ( $arg =~ s/^(\d+)\s+// ) {
                $number = $1 - 1;
            } else {
                $irc->yield( privmsg => $chl => "Invalid rule number!" );
                return;
            }

            # parse the rest of the options
            my %args = &parse_add_args($arg);

            if ( $config->{re_list} and $config->{re_list}[$number] ) {
                $config->{re_list}[$number][CHANNEL] = $args{channel}
                  if ( exists $args{channel} );
                $config->{re_list}[$number][ACTION] = $args{action}
                  if ( exists $args{action} );
                $config->{re_list}[$number][TIMEOUT] = $args{timeout}
                  if ( exists $args{timeout} );
                $config->{re_list}[$number][MESSAGE] = $args{message}
                  if ( exists $args{message} );
                $config->{re_list}[$number][CHANCE] = $args{chance}
                  if ( exists $args{chance} );
                $config->{re_list}[$number][RANGE] = $args{range}
                  if ( exists $args{range} );
                $config->{re_list}[$number][CONTINUE] = $args{continue}
                  if ( exists $args{continue} );
                $config->{re_list}[$number][RE] = $args{re} if ( $args{re} );
                $irc->yield( privmsg => $chl =>
                      &format_rule( $number + 1, $config->{re_list}[$number] )
                );
                &calculate_re;
                &save;
            } else {
                $irc->yield( privmsg => $chl => "No such rule!" );
            }
        } elsif ( $cmd eq 'delete' ) {
            if ( $arg =~ /^\d+$/ and $config->{re_list}[ $arg - 1 ] ) {
                my $line = splice( @{ $config->{re_list} }, $arg - 1, 1 );
                &calculate_re;
                &save;
                &echo( $who, $chl, "Removed line #$arg: $line->[RE]" );
            } else {
                $irc->yield( privmsg => $chl => "Invalid line number $arg" );
            }
        } elsif ( $cmd eq 'list' ) {
            if ( $arg and $arg !~ /^\d+$/ ) {
                eval { qr/$arg/ };
                if ($@) {
                    $irc->yield( privmsg => $chl => "Invalid RE /$arg/: $@" );
                    return;
                }

                my $num = 0;
                foreach ( @{ $config->{re_list} } ) {
                    $num++;
                    next
                      unless $_->[RE] =~ qr/$arg/i
                          or $_->[MESSAGE] =~ qr/$arg/i;
                    $irc->yield( privmsg => $chl =>
                          &format_rule( $num, $config->{re_list}[ $num - 1 ] )
                    );
                }

                return;
            }
            if ( @{ $config->{re_list} } ) {
                if ( $arg and $arg =~ /^\d+$/ ) {
                    $irc->yield( privmsg => $chl =>
                          &format_rule( $arg, $config->{re_list}[ $arg - 1 ] )
                    );
                } elsif ( $arg and $arg =~ /^(\d+)-(\d+)$/ ) {
                    foreach ( $1 .. $2 ) {
                        $irc->yield( privmsg => $chl =>
                              &format_rule( $_, $config->{re_list}[ $_ - 1 ] )
                        );
                    }
                } else {
                    $irc->yield(
                        privmsg => $chl => "Not listing the entire list." );
                }
            } else {
                $irc->yield( privmsg => $chl => "List is empty." );
            }
        } elsif ( $cmd eq 'nostar' ) {
            $arg = "#$arg" unless substr( $arg, 0, 1 ) eq '#';
            $config->{nostar}{$arg} = 1;
            &save;
            &echo( $who, $chl, "$arg will not activate '*' rules" );
        } elsif ( $cmd eq 'star' ) {
            $arg = "#$arg" unless substr( $arg, 0, 1 ) eq '#';
            delete $config->{nostar}{$arg};
            &save;
            &echo( $who, $chl, "$arg will activate '*' rules" );
        } elsif ( $cmd eq 'ignore' ) {
            if ( $arg =~ /^\w+$/ ) {
                $config->{ignore}{ lc $arg } = 1;
                &save;
                &echo( $who, $chl, "Ignoring $arg" );
            } else {
                $irc->yield( privmsg => $chl => "Invalid nick '$arg'" );
            }
        } elsif ( $cmd eq 'unignore' ) {
            if ( $arg =~ /^\w+$/ ) {
                delete $config->{ignore}{ lc $arg };
                &save;
                &echo( $who, $chl, "Not ignoring $arg" );
            } else {
                $irc->yield( privmsg => $chl => "Invalid nick '$arg'" );
            }
        } elsif ( $cmd eq 'part' ) {
            if ( $arg =~ /^#?[-\w]+$/ ) {
                $arg = "#$arg" unless substr( $arg, 0, 1 ) eq '#';
                $irc->yield( part => $arg );
                &echo( $who, $chl, "Leaving $arg" );
                delete $topics{$arg};
            } else {
                $irc->yield( privmsg => $chl => "Invalid channel name '$arg'" );
            }
        } elsif ( $cmd eq 'join' ) {
            if ( $arg =~ /^#?[-\w]+$/ ) {
                $arg = "#$arg" unless substr( $arg, 0, 1 ) eq '#';
                $irc->yield( join => $arg );
                &echo( $who, $chl, "Joining $arg" );
                $topics{$arg} = undef;
            } else {
                $irc->yield( privmsg => $chl => "Invalid channel name '$arg'" );
            }
        } elsif ( $cmd eq 'autojoin' ) {
            if ( $arg =~ /^#?[-\w]+$/ ) {
                $arg = "#$arg" unless substr( $arg, 0, 1 ) eq '#';
                $config->{autojoin}{$arg} = 1;
                &save;
                &echo( $who, $chl, "$arg added to autojoin" );
            } else {
                $irc->yield( privmsg => $chl => "Invalid channel name '$arg'" );
            }
        } elsif ( $cmd eq 'unautojoin' ) {
            if ( $arg =~ /^#?[-\w]+$/ ) {
                $arg = "#$arg" unless substr( $arg, 0, 1 ) eq '#';
                delete $config->{autojoin}{$arg};
                &save;
                &echo( $who, $chl, "$arg removed from autojoin" );
            } else {
                $irc->yield( privmsg => $chl => "Invalid channel name '$arg'" );
            }
        } elsif ( $cmd eq 'nick' ) {
            $irc->yield( nick => $arg );
            &echo( $who, $chl, "nicking to $arg" );
        } elsif ( $cmd eq 'restart' ) {
            &echo( $who, $chl, "restarting" );
            exit;
        } elsif ( $cmd eq 'banlist' ) {
            if ( $arg =~ /\S/ ) {
                my $found = 0;
                foreach my $ban (@banlist) {
                    foreach ( values %$ban ) {
                        if ( index( $_, $arg ) >= 0 ) {
                            if ( $found++ < 20 ) {
                                $irc->yield(
                                    privmsg => $chl => &format_ban($ban) );
                            }
                            last;
                        }
                    }
                }
                if ( $found == 0 ) {
                    $irc->yield(
                        privmsg => $chl => "None of the bans matched." );
                } elsif ( $found >= 20 ) {
                    $irc->yield( privmsg => $chl =>
                          "... $found found, stopped after 20" );
                }
            } else {
                $irc->yield(
                    privmsg => $chl => scalar(@banlist) . " bans known" );
            }
        } elsif ( $cmd eq 'dump' ) {
            print Dumper $config;
        } elsif ( $cmd eq 'help' ) {
            my %help = (
                add => [ "add <args>", "" ],
                'delete' =>
                  [ "delete <line #>", "Remove a line from the rules" ],
                edit => [
                    "edit <line #> <args>",
                    "Edit a given rule, accept the same arguments as add"
                ],
                list => [
                    "list [filter|number|range]",
                    "Show all the rules that match <filter>"
                ],
                banlist => [ "banlist [filter]", "search the ban list" ],
                part =>
                  [ "part #channel", "Leave #channel (for this session)" ],
                'join' =>
                  [ "join #channel", "Join #channel (for this session)" ],
                autojoin => [
                    "autojoin #channel",
                    "Add #channel to the list of always joined channels"
                ],
                unautojoin => [
                    "unautojoin #channel",
                    "Remove #channel from autojoin list"
                ],
                ignore => [ "ignore <nick>", "ignore all lines from nick" ],
                unignore =>
                  [ "unignore <nick>", "remove nick from ignore list" ],
                star => [ "star <chl>", "undo 'nostar' on this channel" ],
                nostar =>
                  [ "nostar <chl>", "ignore '*' rules for this channel" ],
                nick => [
                    "nick <nick>",
                    "renick to nick. "
                      . "note, this does not affect any hardcoded names in rules"
                ],
                restart  => [ "restart", "quit and (hopefully), restart" ],
                stopword => [
                    "stopword <string>",
                    "kickban the next person to mention"
                      . " the string in this channel"
                ],
                extend => [
                    "extend that by <time>",
                    "extends the last ban by the specified time.  "
                      . "Accepts 3m, 2h, etc."
                ],
                help => [ "help <cmd>", "show more detailed help on cmd" ],
            );
            if ($arg) {
                if ( $arg eq 'add' ) {
                    $irc->yield( privmsg => $chl => $_ ) foreach (
                        "Add a new action line: add [options] <regular expression>",
                        "optional flags:",
                        "-channels \"#chan1 #chan2\" | -channel #chan1",
                        "-action (kb|ko|kn|shutup|kick|say|do|spam)",
                        "-timeout nnn[smhd]-nnn[smhd] "
                        . "(for ko, kick, say and do, range optional)",
                        "-message \"something to say\" (kick message)",
                        "-prob nn% (defaults to 100%)",
                        "-continue (examine rules after this match)",
                    );
                } elsif ( exists $help{$arg} ) {
                    $irc->yield(
                        privmsg => $chl => join " - ",
                        @{ $help{$arg} }
                    );
                } else {
                    $irc->yield(
                        privmsg => $chl => "No detailed help for $arg" );
                }
            } else {
                $irc->yield(
                    privmsg => $chl => "Commands: " . join " | ",
                    sort keys %help
                );
            }
        }
    } else {
        Log("not talking to $who");
    }

    return;
}

sub irc_on_connect {
    Log("Connected...");
    Log("Identifying...");
    $irc->yield( privmsg => nickserv => "identify $pass" );
    $irc->yield( mode    => $nick    => "+B" );
    Log("Done.");
}

sub irc_on_public {
    my ($who) = split /!/, $_[ARG0];
    my $chl = $_[ARG1];
    $chl = $chl->[0];
    my $msg = $_[ARG2];

    if ( $chl eq $channel ) {
        &irc_on_msg(@_);
        return;
    }

    if ( exists $config->{ignore}{ lc $who } ) {
        # Log("ignoring $who");
        return;
    }

    &act( $chl, $chl, $who, $_[ARG0], $msg )
      or not exists $config->{nostar}{$chl}
      and &act( $chl, "*", $who, $_[ARG0], $msg );

    if (   $irc->is_channel_operator( $channel, $who )
        or $irc->is_channel_owner( $channel, $who )
        or $irc->is_channel_admin( $channel, $who ) )
    {
        if ( $msg =~ /^$nick[:,]\s*stopword (.*)/i ) {
            my $arg = $1;
            $arg =~ s/^\s+|\s+$//g;
            $stopword{$arg} = [ $chl, time ];
            $irc->yield( privmsg => $chl =>
                  "Okay, next person to say '$arg' gets kickbanned." );
            $irc->yield( privmsg => $channel => "$who set stopword '$arg'" );
            Log "$who set stopword $arg in $chl";
            return;
        }

        if ( $msg =~ /^$nick[:,] extend (?:that )?(?:by )?(\d+) *([mh])/ ) {
            if ($last_timer) {
                my $flags = $irc->delay_remove($last_timer);
                $last_expire += $1 * ( $2 eq 'm' ? 60 : 3600 );
                if ( ref $flags and $last_expire > time ) {
                    my $mask = $flags->[3];
                    $last_timer = $irc->delay( $flags, $last_expire - time );
                    $irc->yield(
                        privmsg => $chl => "Okay, extending $mask ban." );
                    $irc->yield( privmsg => $channel =>
                            "$who set extended ban by $1$2, now expiring in "
                          . ( $last_expire - time )
                          . " seconds." );
                    Log "$who extended ban in $chl by $1$2";
                    return;
                }
            }

            $irc->yield( privmsg => $chl => "Sorry, you're too late." );
            return;
        }
    }
}

sub act {
    my ( $chl, $chanmask, $who, $userhost, $msg ) = @_;

    if ( defined $config->{re}{$chanmask} and $msg =~ $config->{re}{$chanmask} )
    {
        my $c = 0;
        foreach my $re ( @{ $config->{re_list} } ) {
            $c++;
            next unless $re->[CHANNEL] eq $chanmask;
            next unless $re->[COMPILED];
            next unless $msg =~ $re->[COMPILED];

            if ( $userhost =~ /ip$/i ) {
                $userhost =~ s/@[^.]+\./@*./;
            } else {
                $userhost =~ s/@[^.]+\./@*./;
            }
            $userhost =~ s/^.*!/*!/;

            Log( "Matched: ", Dumper $re);

            if ( $re->[CHANCE] and $re->[CHANCE] < 100 ) {
                unless ( rand(100) < $re->[CHANCE] ) {
                    Log("failed to executing ($re->[CHANCE]%)");
                    next;
                }
            }

            my $timeout = $re->[TIMEOUT];
            if ( $re->[TIMEOUT] and $re->[RANGE] ) {
                $timeout += int( rand( $re->[RANGE] - $re->[TIMEOUT] ) );
                $irc->yield( privmsg => $channel =>
                        "$who triggered $re->[ACTION] (rule $c: /$re->[RE]/) "
                      . "for ${timeout}s in $chl" );
            } else {
                $irc->yield( privmsg => $channel =>
                        "$who triggered $re->[ACTION] (rule $c: /$re->[RE]/) "
                      . "in $chl" );
            }

            if ( $re->[ACTION] eq 'kick' ) {
                Log("kicking ($chl: $timeout) $re->[MESSAGE]");
                &yield_or_delay(
                    $timeout,
                    kick => $chl,
                    $who, $re->[MESSAGE] || "PUNT"
                );
            } elsif ( $re->[ACTION] eq 'say' ) {
                Log("saying ($chl: $timeout) $re->[MESSAGE]");
                &yield_or_delay(
                    $timeout,
                    privmsg => $chl,
                    $re->[MESSAGE] || "Goatgoatgoat"
                );
            } elsif ( $re->[ACTION] eq 'do' ) {
                Log("doing ($chl: $timeout) $re->[MESSAGE]");
                &yield_or_delay(
                    $timeout,
                    ctcp => $chl,
                    "ACTION $re->[MESSAGE]"
                );
            } elsif ( $re->[ACTION] eq 'kickban' ) {
                Log("kbing ($chl) $userhost, $re->[MESSAGE]");
                &ban( $chl, $userhost );
                &kick( $chl, $who, $re->[MESSAGE] );
            } elsif ( $re->[ACTION] eq 'knockout' ) {
                Log("koing ($chl) $userhost, $re->[MESSAGE] for $timeout");
                &ban( $chl, $userhost, $timeout );
                &kick( $chl, $who, $re->[MESSAGE] );
            } elsif ( $re->[ACTION] eq 'shutup' ) {
                Log( "shutting up ($chl) $userhost, $re->[MESSAGE] for $timeout"
                );
                &ban( $chl, "~q:$userhost", $timeout );
                if ( $re->[MESSAGE] ) {
                    $irc->yield( privmsg => $chl => $re->[MESSAGE] );
                }
            } elsif ( $re->[ACTION] eq 'spam' ) {
                my $mode = $re->[MESSAGE];
                unless ($mode =~ /^\+[MRNtmiG]+$/) {
                    Log( "Ignoring invalid mode: $re->[MESSAGE]" );
                    next;
                }
                $mode =~ s/\+//;

                if ( exists $spam_counter{$chl}{$mode}
                    and time - $spam_counter{$chl}{$mode}[0] < 10 )
                {
                    $spam_counter{$chl}{$mode}[0] = time;
                    $spam_counter{$chl}{$mode}[1]++;
                } else {
                    $spam_counter{$chl}{$mode} = [ time, 1 ];
                }

                Log( "Triggering '$mode' spam token in $chl. Current" .
                     " count: $spam_counter{$chl}{$mode}[1].");

                if (
                    $spam_counter{$chl}{$mode}[1] > SPAM_TOLERANCE
                    and ( not exists $mode_set{$chl}{$mode}
                        or time - $mode_set{$chl}{$mode} > $timeout )
                  )
                {
                    Log( "Setting mode +$mode on $chl" );
                    $irc->yield( privmsg => $chl =>
                            "Locking down channel. If you can't speak, register your nick. "
                          . "/msg nickserv help register" );
                    &mode( $chl, $mode, $timeout );
                }
            }

            last unless $re->[CONTINUE];
        }
    }

    foreach my $stop ( keys %stopword ) {
        next unless $chl eq $stopword{$stop}[0];
        next unless $msg =~ /\b\Q$stop\E\b/i;

        if ( time - $stopword{$stop}[1] > 600 ) {
            delete $stopword{$stop};
            next;
        }

        if ( $userhost =~ /ip$/i ) {
            $userhost =~ s/@[^.]+\./@*./;
        } else {
            $userhost =~ s/@[^.]+\./@*./;
        }

        $userhost =~ s/^.*!/*!/;
        $irc->yield( privmsg => $channel => "$who triggered stopword $stop" );
        Log "$who triggered stopword $stop in $chl";
        &ban( $chl, $userhost, 300 );
        &kick( $chl, $who, "Jackpot!!!" );

        delete $stopword{$stop};
        last;
    }
}

sub yield_or_delay {
    my ( $timeout, @args ) = @_;
    if ($timeout) {
        $irc->delay( [@args], $timeout );
    } else {
        $irc->yield(@args);
    }
}

sub format_rule {
    my ( $num, $rule ) = @_;

    return sprintf(
        "%d. chl:%s act:%s%s%s%s%s re:/%s/",
        $num,
        $rule->[CHANNEL],
        $rule->[ACTION],
        (
            $rule->[TIMEOUT]
            ? (
                $rule->[RANGE]
                ? " time:$rule->[TIMEOUT]-$rule->[RANGE]"
                : " time:$rule->[TIMEOUT]"
              )
            : ""
        ),
        ( $rule->[MESSAGE] ? " msg:\"$rule->[MESSAGE]\"" : "" ),
        (
                  $rule->[CHANCE]
              and $rule->[CHANCE] != 100 ? " prob:$rule->[CHANCE]%" : ""
        ),
        ( $rule->[CONTINUE] ? "-cont" : "" ),
        $rule->[RE]
    );
}

sub parse_add_args {
    my $arg = shift;
    my %args;
    if ( $arg =~ s/(?:-?channels?|-?chls?|-c)(?: +|:)("[^"]+"|\S+)\b\s*//i ) {
        $args{channel} = $1;
        $args{channel} =~ s/^"|"$//g;
    }

    if (
        $arg =~ s/(?:-?action|-a) (?:\s+|:)
                       (?:(kickban|kb)|
                          (knockout|kn|ko)|
                          (shutup|shush)|
                          (kick|k)|
                          (say|s)|
                          (spam)|
                          (do|d)
                          )\b\s*//ix
      )
    {
        $args{action} =
            $1 ? "kickban"
          : $2 ? "knockout"
          : $3 ? "shutup"
          : $4 ? "kick"
          : $5 ? "say"
          : $6 ? "spam"
          :      "do";
    }

    if (
        $arg =~ s/(?:-?timeout|-time|-t) # flag
                   (?:\s+|:)              # space or :
                   (\d+) ([smhd])?        # time spec
                   (?:- (\d+) ([smhd])?)? # range spec
                   \b\s*                  # trailing spaces
                 //ix
      )
    {
        $args{timeout} = $1;
        if ( lc $2 eq 'm' ) {
            $args{timeout} *= 60;
        } elsif ( lc $2 eq 'h' ) {
            $args{timeout} *= 3600;
        } elsif ( lc $2 eq 'd' ) {
            $args{timeout} *= 86400;
        }

        if ($3) {
            $args{range} = $3;

            if ( lc $4 eq 'm' ) {
                $args{range} *= 60;
            } elsif ( lc $4 eq 'h' ) {
                $args{range} *= 3600;
            } elsif ( lc $4 eq 'd' ) {
                $args{range} *= 86400;
            }
        }
    }

    if ( $arg =~ s/(?:-?msg|-?message|-?say|-[sm])(?: +|:)("[^"]+"|\S+)\s*//i )
    {
        $args{message} = $1;
        $args{message} =~ s/^"|"$//g;
    }

    if ( $arg =~ s/-?(?:probability|prob)(?: +|:)(\d+)%?\s*//i ) {
        $args{chance} = $1;
    }

    if ( $arg =~ s/-?(?:continue|cont)\s*//i ) {
        $args{continue} = $1;
    }

    # whatever we have left is our RE
    $args{re} = $arg;

    return %args;
}

sub mode {
    my ( $chl, $mode, $timeout ) = @_;
    $irc->yield( mode => $chl, $mode );
    $timeout ||= 300;    # default timeout is 5 minutes if it's not specified
    $irc->delay( [ mode => $chl, "-$mode" ], $timeout );
    $mode_set{$chl}{$mode} = time;
}

sub ban {
    my ( $chl, $mask, $timeout ) = @_;
    $irc->yield( mode => $chl, "+b", $mask );
    $timeout ||= 300;    # default timeout is 5 minutes if it's not specified
    $last_timer = $irc->delay( [ mode => $chl, "-b", $mask ], $timeout );
    $last_expire = time + $timeout;
}

sub kick {
    my ( $chl, $nick, $msg ) = @_;
    $irc->yield( kick => $chl, $nick, $msg || "PUNT" );
}

sub save {
    DumpFile( $configfile, $config );
}

sub calculate_re {
    delete $config->{re};
    foreach my $re ( @{ $config->{re_list} } ) {
        $config->{re}{ $re->[CHANNEL] } = join "|",
          $config->{re}{ $re->[CHANNEL] },
          $re->[RE];
        eval { $re->[COMPILED] = qr/$re->[RE]/ };
        if ($@) {
            Log "Failed to compile $re->[RE]: $@";
        }
    }
    foreach my $chan ( keys %{ $config->{re} } ) {
        $config->{re}{$chan} = qr/$config->{re}{$chan}/i;
    }
    print "RE: ", Dumper $config->{re};
}

sub format_ban {
    my $ban = shift;
    return sprintf(
        "%16s %16s %s (%s)",
        @{$ban}{qw/chan who ban/},
        scalar localtime $ban->{when}
    );
}
