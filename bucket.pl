#!/usr/bin/perl -w
#
# $Id: bucket.pl 645 2009-05-21 22:30:53Z dan $

use strict;
use POE;
use POE::Component::IRC;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::NickServID;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::SimpleDBI;
use YAML qw/LoadFile DumpFile/;
use Data::Dumper;
use Fcntl qw/:seek/;
$Data::Dumper::Indent = 1;

use constant { DEBUG => 0 };

my $VERSION = '$Id: bucket.pl 645 2009-05-21 22:30:53Z dan $';

$SIG{CHLD} = 'IGNORE';

$|++;

### IRC portion
my $configfile = "/home/bucket/bucket.yml";
my $config     = LoadFile($configfile);
my $nick       = $config->{nick} || "Bucket";
my $pass       = $config->{password} || "somethingsecret";
$nick = DEBUG ? ( $config->{debug_nick} || "bucketgoat" ) : $nick;
my $channel =
  DEBUG
  ? ( $config->{debug_channel} || "#zigdon" )
  : ( $config->{controll_channel} || "#billygoat" );
my ($irc) = POE::Component::IRC::State->spawn();
my %channels = ( $channel => 1 );
my $mainchannel = $config->{main_channel} || "#xkcd";
my %talking;
my %fcache;
my %stats;
my %undo;
my %last_activity;

$stats{startup_time} = time;

if ( $config->{logfile} ) {
    open( LOG, ">>$config->{logfile}" )
      or die "Can't write $config->{logfile}: $!";
}

$irc->plugin_add( 'NickServID',
    POE::Component::IRC::Plugin::NickServID->new( Password => $pass ) );

POE::Component::SimpleDBI->new('db') or die "Can't create DBI session";

POE::Session->create(
    inline_states => {
        _start           => \&irc_start,
        irc_001          => \&irc_on_connect,
        irc_public       => \&irc_on_public,
        irc_ctcp_action  => \&irc_on_public,
        irc_msg          => \&irc_on_public,
        irc_notice       => \&irc_on_notice,
        irc_disconnected => \&irc_on_disconnect,
        db_success       => \&db_success,
        delayed_post     => \&delayed_post,
        check_idle       => \&check_idle,
    },
);

POE::Kernel->run;
print "POE::Kernel has left the building.\n";

sub Log {
    print scalar localtime, " - @_\n";
    if ( $config->{logfile} ) {
        print LOG scalar localtime, " - @_\n";
    }
}

sub Report {
    my $kernel = shift;
    my $delay = shift if $_[0] =~ /^\d+$/;
    if ( $config->{logchannel} and $irc ) {
        if ($delay) {
            Log "Delayed msg ($delay): @_";
            $kernel->delay_add(
                delayed_post => 2 * $delay => $config->{logchannel} => "@_" );
        } else {
            $irc->yield( privmsg => $config->{logchannel} => "@_" );
        }
    }
}

sub delayed_post {
    $irc->yield( privmsg => $_[ARG0], $_[ARG1] );
}

sub irc_on_public {
    my ($who) = split /!/, $_[ARG0];
    my $type  = $_[STATE];
    my $chl   = $_[ARG1];
    $chl = $chl->[0];
    my $msg = $_[ARG2];

    if ( not $stats{tail_time} or time - $stats{tail_time} > 60 ) {
        &tail( $_[KERNEL] );
        $stats{tail_time} = time;
    }

    $last_activity{$chl} = time;

    if ( exists $config->{ignore}{ lc $who } ) {

        Log("ignoring $who");
        return;
    }

    my $operator = 0;
    if (   $irc->is_channel_operator( $channel, $who )
        or $irc->is_channel_owner( $channel, $who )
        or $irc->is_channel_admin( $channel, $who )
        or $irc->is_channel_operator( $mainchannel, $who )
        or $irc->is_channel_owner( $mainchannel, $who )
        or $irc->is_channel_admin( $mainchannel, $who ) )
    {
        $operator = 1;
    }

    my $addressed = 0;
    if ( $type eq 'irc_msg' or $msg =~ s/^$nick[:,]\s*|,\s+$nick\W+$//i ) {
        $addressed = 1;
    } else {
        $msg =~ s/^\S+://;
    }

    $msg =~ s/^\s+|\s+$//g;

    # == 0 - shut up by operator
    # == -1 - talking
    # > 0 - shut up by user, until time()
    $talking{$chl} = -1 unless exists $talking{$chl};
    $talking{$chl} = -1 if ( $talking{$chl} > 0 and $talking{$chl} < time );
    unless ( $talking{$chl} == -1 or ( $operator and $addressed ) ) {
        return;
    }

    if ( time - $stats{last_updated} > 600 ) {
        &get_stats( $_[KERNEL] );
    }

    if ( $type eq 'irc_msg' ) {
        $chl = $who;
    }

    if ( rand(100) < $config->{bananas_chance} ) {
        $irc->yield( privmsg => $chl => "Bananas!" );
    }

    my $editable = 0;
    $editable = 1
      if ( $type eq 'irc_public' and $chl ne '#bots' )
      or ( $type eq 'irc_msg' and $operator );
    Log("$type($chl): $who(o=$operator, a=$addressed, e=$editable): $msg");

    if (
            $editable
        and $msg =~ m{ (.*?)         # $1 key to edit
                   \s+(?:=~|~=)\s+   # match operator
                   s/                # start match
                     (               # $2 - string to replace
                      (?:
                        \\/ |        # escaped slashes are ok
                        [^/]         # anything but a slash
                      )+
                     )               # end of $2
                   /                 # separator
                    (.*)             # $3 - text to replace with
                   /
                   ([gi]*)           # $4 - i/g flags
                   \s* $             # trailing spaces
                 }x
      )
    {
        my ( $fact, $old, $new, $flag ) = ( $1, $2, $3, $4 );
        Report $_[KERNEL],
          "$who is editing $fact in $chl: replacing '$old' with '$new'";
        Log "Editing $fact: replacing '$old' with '$new'";
        $_[KERNEL]->post(
            db  => 'MULTIPLE',
            SQL => 'select * ' . 'from bucket_facts where fact = ? order by id',
            PLACEHOLDERS => [$fact],
            BAGGAGE      => {
                cmd   => "edit",
                who   => $who,
                chl   => $chl,
                fact  => $fact,
                old   => $old,
                'new' => $new,
                flag  => $flag,
                op    => $operator,
            },
            EVENT => 'db_success'
        );
    } elsif (
        $msg =~ m{ (.*?)             # $1 key to look up
                   \s+(?:=~|~=)\s+   # match operator
                   /                 # start match
                     (               # $2 - string to replace
                      (?:
                        \\/ |        # escaped slashes are ok
                        [^/]         # anything but a slash
                      )+
                     )               # end of $2
                   /                 # separator
            }x
      )
    {
        my ( $fact, $search ) = ( $1, $2 );
        $search =~ s{([\\/%?"'])}{\\$1}g;
        $fact = &trim($fact);
        Log "Looking up a particular factoid - '$search' in '$fact'";
        $_[KERNEL]->post(
            db  => 'SINGLE',
            SQL => qq{select id, fact, verb, tidbit from bucket_facts 
                            where fact = ? and tidbit like "%$search%"
                            order by rand(} . int( rand(1e6) ) . ') limit 1',
            PLACEHOLDERS => [$fact],
            BAGGAGE      => {
                cmd       => "fact",
                chl       => $chl,
                msg       => $msg,
                orig      => $msg,
                who       => $who,
                addressed => $addressed,
                editable  => $editable,
                op        => $operator,
            },
            EVENT => 'db_success'
        );
    } elsif ( $msg =~ /^literal(?:\[(\d+)\])?\s+(.*)/i ) {
        my ( $page, $fact ) = ( $1 || 1, $2 );
        $stats{literal}++;
        $fact = &trim($fact);
        Log "Literal[$page] $fact";
        $_[KERNEL]->post(
            db  => 'MULTIPLE',
            SQL => 'select verb, tidbit, mood, chance, protected
                                from bucket_facts where fact = ? order by id',
            PLACEHOLDERS => [$fact],
            BAGGAGE      => {
                cmd  => "literal",
                who  => $who,
                chl  => $chl,
                page => $page,
                fact => $fact
            },
            EVENT => 'db_success'
        );
    } elsif ( $addressed and $operator and $msg =~ /^delete (.*)/i ) {
        my $fact = $1;
        $stats{deleted}++;
        $_[KERNEL]->post(
            db  => "MULTIPLE",
            SQL => "select fact, tidbit, verb, RE, protected, mood, chance
                                   from bucket_facts where fact = ?",
            PLACEHOLDERS => [$fact],
            EVENT        => "db_success",
            BAGGAGE      => {
                cmd  => "delete",
                chl  => $chl,
                who  => $who,
                fact => $fact,
            }
        );
    } elsif (
        $addressed
        and $msg =~ /^(?:shut \s up | go \s away)
                      (?: \s for \s (\d)([smh])?|
                          \s for \s a \s (bit|moment|while|min(?:ute)?))?[.!]?$/xi
      )
    {
        $stats{shutup}++;
        my ( $num, $unit, $word ) = ( $1, lc $2, lc $3 );
        if ($operator) {
            my $target = 0;
            if ($num) {
                $target += $num if not $unit or $unit eq 's';
                $target += $num * 60 if $unit eq 'm';
                $target += $num * 60 * 60 if $unit eq 'h';
                Report $_[KERNEL],
                  "Shutting up in $chl at ${who}'s request for $target seconds";
                $irc->yield(
                    privmsg => $chl => "Okay $who.  I'll be back later" );
                $talking{$chl} = time + $target;
            } elsif ($word) {
                $target += 60 if $word eq 'min' or $word eq 'minute';
                $target += 30 + int( rand(60) )           if $word eq 'moment';
                $target += 4 * 60 + int( rand( 4 * 60 ) ) if $word eq 'bit';
                $target += 30 * 60 + int( rand( 30 * 60 ) ) if $word eq 'while';
                Report $_[KERNEL],
                  "Shutting up in $chl at ${who}'s request for $target seconds";
                $irc->yield(
                    privmsg => $chl => "Okay $who.  I'll be back later" );
                $talking{$chl} = time + $target;
            } else {
                Report $_[KERNEL],
                  "Shutting up in $chl at ${who}'s request until called back";
                $talking{$chl} = 0;
                $irc->yield( privmsg => $chl =>
                      "$who: shutting up (until told to 'come back')" );
            }
        } else {
            $irc->yield( privmsg => $chl => "Okay, $who - be back in a bit!" );
            $talking{$chl} = time + $config->{timeout};
        }
    } elsif ( $addressed
        and $operator
        and $msg =~ /^unshut up\W*$|^come back\W*$/i )
    {
        $irc->yield( privmsg => $chl => "\\o/" );
        $talking{$chl} = -1;
    } elsif ( $addressed and $operator and $msg =~ /^(join|part) (#\w+)/i ) {
        my ( $cmd, $dst ) = ( $1, $2 );
        unless ($dst) {
            $irc->yield( privmsg => $chl => "$who: $cmd what channel?" );
            return;
        }
        $irc->yield( $cmd => $dst );
        $irc->yield( privmsg => $chl => "$who: ${cmd}ing $dst" );
    } elsif ( $addressed and $operator and lc $msg eq 'list ignored' ) {
        $irc->yield(
            privmsg => $chl => "Currently ignored: ",
            join ", ", sort keys %{ $config->{ignore} }
        );
    } elsif ( $addressed and $operator and $msg =~ /^(un)?ignore (\S+)/i ) {
        if ($1) {
            delete $config->{ignore}{ lc $2 };
        } else {
            $config->{ignore}{ lc $2 } = 1;
        }
        &save;
        $irc->yield( privmsg => $chl => "Okay, $who.  Ignore list updated." );
    } elsif ( $addressed and $operator and $msg =~ /^(un)?protect (.+)/i ) {
        my ( $protect, $fact ) = ( ( $1 ? 0 : 1 ), $2 );
        Report $_[KERNEL], "$who is $1protecting $fact";
        Log "$1protecting $fact";
        $_[KERNEL]->post(
            db           => "DO",
            SQL          => 'update bucket_facts set protected=? where fact=?',
            PLACEHOLDERS => [ $protect, $fact ],
            EVENT        => "db_success",
        );
        $irc->yield(
            privmsg => $chl => "Okay, $who, updated the protection bit." );
    } elsif ( $addressed and $operator and $msg =~ /^undo last(?: (#\S+))?/ ) {
        Log "$who called undo:";
        my $uchannel = $1 || $chl;
        my $undo = $undo{$uchannel};
        Log Dumper $undo;
        if ( $undo->[0] eq 'delete' ) {
            $_[KERNEL]->post(
                db           => "DO",
                SQL          => 'delete from bucket_facts where id=? limit 1',
                PLACEHOLDERS => [ $undo->[1] ],
                EVENT        => "db_success",
            );
            Report $_[KERNEL], "$who called undo: deleted $undo->[2].";
            $irc->yield( privmsg => $chl => "Okay, $who, deleted $undo->[2]." );
            delete $undo{$uchannel};
        } elsif ( $undo->[0] eq 'insert' ) {
            if ( $undo->[1] and ref $undo->[1] eq 'ARRAY' ) {
                foreach my $entry ( @{ $undo->[1] } ) {
                    my %old = %$entry;
                    $old{RE}        = 0 unless $old{RE};
                    $old{protected} = 0 unless $old{protected};
                    $_[KERNEL]->post(
                        db  => "DO",
                        SQL => 'insert bucket_facts 
                                (fact, verb, tidbit, protected, RE, mood, chance)
                                values(?, ?, ?, ?, ?, ?, ?)',
                        PLACEHOLDERS => [
                            @old{ qw/fact verb tidbit protected RE mood chance/
                              }
                        ],
                        EVENT => "db_success",
                    );
                }
                Report $_[KERNEL], "$who called undo: undeleted $undo->[2].";
                $irc->yield(
                    privmsg => $chl => "Okay, $who, undeleted $undo->[2]." );
            } elsif ( $undo->[1] and ref $undo->[1] eq 'HASH' ) {
                my %old = %{ $undo->[1] };
                $old{RE}        = 0 unless $old{RE};
                $old{protected} = 0 unless $old{protected};
                $_[KERNEL]->post(
                    db  => "DO",
                    SQL => 'insert bucket_facts 
                            (id, fact, verb, tidbit, protected, RE, mood, chance)
                            values(?, ?, ?, ?, ?, ?, ?, ?)',
                    PLACEHOLDERS => [
                        @old{qw/id fact verb tidbit protected RE mood chance/}
                    ],
                    EVENT => "db_success",
                );
                Report $_[KERNEL], "$who called undo:",
                  "unforgot $old{fact} $old{verb} $old{tidbit}.";
                $irc->yield( privmsg => $chl =>
                      "Okay, $who, unforgot $old{fact} $old{verb} $old{tidbit}."
                );
            } else {
                $irc->yield( privmsg => $chl =>
                        "Sorry, $who, that's an invalid undo structure."
                      . "  Tell Zigdon, please." );
            }

        } elsif ( $undo->[0] eq 'edit' ) {
            if ( $undo->[1] and ref $undo->[1] eq 'ARRAY' ) {
                foreach my $entry ( @{ $undo->[1] } ) {
                    if ( $entry->[0] eq 'update' ) {
                        $_[KERNEL]->post(
                            db  => "DO",
                            SQL => 'update bucket_facts
                                            set verb=?, tidbit=? where id=? limit 1',
                            PLACEHOLDERS =>
                              [ $entry->[2], $entry->[3], $entry->[1] ],
                            EVENT => "db_success",
                        );
                    } elsif ( $entry->[0] eq 'insert' ) {
                        my %old = %{ $entry->[1] };
                        $old{RE}        = 0 unless $old{RE};
                        $old{protected} = 0 unless $old{protected};
                        $_[KERNEL]->post(
                            db  => "DO",
                            SQL => 'insert bucket_facts 
                                    (fact, verb, tidbit, protected, RE, mood, chance)
                                    values(?, ?, ?, ?, ?, ?, ?)',
                            PLACEHOLDERS => [
                                @old{
                                    qw/fact verb tidbit protected RE mood chance/
                                  }
                            ],
                            EVENT => "db_success",
                        );
                    }
                }
                Report $_[KERNEL], "$who called undo: undone $undo->[2].";
                $irc->yield(
                    privmsg => $chl => "Okay, $who, undone $undo->[2]." );
            } else {
                $irc->yield( privmsg => $chl =>
                        "Sorry, $who, that's an invalid undo structure."
                      . "  Tell Zigdon, please." );
            }
            delete $undo{$uchannel};
        } else {
            $irc->yield(
                privmsg => $chl => "Sorry, $who, can't undo $undo->[0] yet" );
        }
    } elsif ( $addressed and $operator and $msg =~ /^alias (.*) => (.*)/ ) {
        my ( $src, $dst ) = ( $1, $2 );
        $stats{alias}++;

        $_[KERNEL]->post(
            db  => 'SINGLE',
            SQL => 'select id, verb, tidbit 
                    from bucket_facts where fact = ? limit 1',
            PLACEHOLDERS => [$src],
            BAGGAGE      => {
                cmd => "alias1",
                chl => $chl,
                src => $src,
                dst => $dst,
                who => $who,
            },
            EVENT => 'db_success'
        );
    } elsif ( $operator and $addressed and $msg =~ /^lookup (\d+)$/ ) {
        $_[KERNEL]->post(
            db  => 'SINGLE',
            SQL => 'select id, fact, verb, tidbit from bucket_facts 
                            where id = ? ',
            PLACEHOLDERS => [$1],
            BAGGAGE      => {
                cmd       => "fact",
                chl       => $chl,
                msg       => $1,
                orig      => $1,
                who       => $who,
                addressed => 0,
                editable  => 0,
                op        => 0,
                type      => $type,
            },
            EVENT => 'db_success'
        );
    } elsif ( $operator and $addressed and $msg =~ /^forget (?:that|#(\d+))$/ )
    {
        my $id = $1 || $stats{last_fact}{$chl};
        unless ($id) {
            $irc->yield( privmsg => $chl => "Sorry, $who, forget what?" );
            return;
        }

        $_[KERNEL]->post(
            db  => 'SINGLE',
            SQL => 'select * from bucket_facts 
                            where id = ? ',
            PLACEHOLDERS => [$id],
            BAGGAGE      => {
                cmd => "forget",
                chl => $chl,
                who => $who,
                msg => $msg,
                id  => $id,
            },
            EVENT => 'db_success'
        );

    } elsif ( $addressed and $msg =~ /suggest a band name/i ) {
        $_[KERNEL]->post(
            db  => 'SINGLE',
            SQL => 'select band from band_names 
                            order by rand(' . int( rand(1e6) ) . ') limit 1 ',
            BAGGAGE => {
                cmd       => "band_name_suggest",
                chl       => $chl,
                who       => $who,
                addressed => 0,
                editable  => 0,
                op        => 0,
                type      => 'irc_public',
            },
            EVENT => 'db_success'
        );
    } elsif ( $addressed and $msg eq 'something random' ) {
        $_[KERNEL]->post(
            db  => 'SINGLE',
            SQL => 'select id, fact, verb, tidbit from bucket_facts 
                            order by rand(' . int( rand(1e6) ) . ') limit 1 ',
            BAGGAGE => {
                cmd       => "fact",
                chl       => $chl,
                msg       => undef,
                orig      => undef,
                who       => $who,
                addressed => 0,
                editable  => 0,
                op        => 0,
                type      => 'irc_public',
            },
            EVENT => 'db_success'
        );
    } elsif ( $addressed and $msg eq 'stats' ) {
        $irc->yield(
            privmsg => $chl => sprintf(
                join( " ",
                    "I've been awake since %s.",
                    "In that time, I learned %d new thing%s,",
                    "updated %d thing%s,",
                    "and forgot %d thing%s.",
                    "That brings me to a total of %s",
                    "things I know about %s subjects." ),
                scalar localtime( $stats{startup_time} ),
                $stats{learn},
                ( $stats{learn} == 1 ? "" : "s" ),
                $stats{edited},
                ( $stats{edited} == 1 ? "" : "s" ),
                $stats{deleted},
                ( $stats{deleted} == 1 ? "" : "s" ),
                $stats{rows},
                $stats{triggers}
            )
        );
    } elsif ( $operator and $addressed and $msg eq 'restart' ) {
        Report $_[KERNEL], "Restarting at ${who}'s request";
        Log "Restarting at ${who}'s request";
        $irc->yield( privmsg => $chl => "Okay, $who, I'll be right back." );
        $irc->yield( quit => "OHSHI--" );
    } elsif ( $operator and $addressed and $msg =~ /^set (\w+) (.*)/ ) {
        my ( $key, $val ) = ( $1, $2 );
        if ( $key eq 'band_name' and $val =~ /^(\d+)%?$/ ) {
            $config->{band_name} = $1;
        } elsif ( $key eq 'bananas_chance' and $val =~ /^([\d.]+)%?$/ ) {
            $config->{bananas_chance} = $1;
        } elsif ( $key eq 'random_wait' and $val =~ /^(\d+)$/ ) {
            $config->{random_wait} = $1;
        } else {
            return;
        }
        $irc->yield( privmsg => $chl => "Okay, $who." );
        Report $_[KERNEL], "$who set '$key' to '$val'";

        &save;
        return;
    } elsif ( $operator and $addressed and $msg =~ /^get (\w+)/ ) {
        my ($key) = ($1);
        return unless ( $key =~ /^(?:band_name|bananas_chance|random_wait)$/ );

        $irc->yield( privmsg => $chl => "$key is $config->{$key}." );
    } else {
        my $orig = $msg;
        $msg = &trim($msg);
        if ( $addressed or length $msg >= 6 or $msg eq '...' ) {
            if ( $addressed and length $msg == 0 ) {
                $msg = "Bucket";
            }

            #Log "Looking up $msg";
            $_[KERNEL]->post(
                db  => 'SINGLE',
                SQL => 'select id, fact, verb, tidbit from bucket_facts 
                                where fact = ? order by rand('
                  . int( rand(1e6) ) 
                  . ') limit 1',
                PLACEHOLDERS => [$msg],
                BAGGAGE      => {
                    cmd       => "fact",
                    chl       => $chl,
                    msg       => $msg,
                    orig      => $orig,
                    who       => $who,
                    addressed => $addressed,
                    editable  => $editable,
                    op        => $operator,
                    type      => $type,
                },
                EVENT => 'db_success'
            );
        }
    }
}

sub db_success {
    my $res = $_[ARG0];

    print Dumper $res;
    my %bag = ref $res->{BAGGAGE} ? %{ $res->{BAGGAGE} } : {};
    if ( $res->{ERROR} ) {
        Report $_[KERNEL], "DB Error: $res->{QUERY} -> $res->{ERROR}";
        Log "DB Error: $res->{QUERY} -> $res->{ERROR}";
        &error( $bag{chl}, $bag{who} ) if $bag{chl};
        return;
    }

    if ( $bag{cmd} eq 'fact' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        if ( defined $line{tidbit} ) {

            if ( $line{verb} eq '<alias>' ) {
                if ( $bag{aliases}{ $line{tidbit} } ) {
                    Report $_[KERNEL], "Alias loop detected when '$line{fact}'"
                      . " is aliased to '$line{tidbit}'";
                    Log "Alias loop detected when '$line{fact}'"
                      . " is aliased to '$line{tidbit}'";
                    &error( $bag{chl}, $bag{who} );
                    return;
                }
                $bag{aliases}{ $line{tidbit} } = 1;

                Log "Following alias '$line{fact}' -> '$line{tidbit}'";
                $_[KERNEL]->post(
                    db  => 'SINGLE',
                    SQL => 'select fact, verb, tidbit from bucket_facts 
                                    where fact = ? order by rand('
                      . int( rand(1e6) ) 
                      . ') limit 1',
                    PLACEHOLDERS => [ $line{tidbit} ],
                    BAGGAGE      => { %bag, msg => $line{tidbit} },
                    EVENT        => 'db_success'
                );
                return;
            }

            $bag{msg}  = $line{fact} unless defined $bag{msg};
            $bag{orig} = $line{fact} unless defined $bag{orig};

            $stats{last_fact}{ $bag{chl} } = $line{id};
            $stats{lookup}++;
            $line{tidbit} =~ s/\$who/$bag{who}/gi;
            if ( $line{tidbit} =~ /\$someone/i ) {
                my @nicks = $irc->nicks();
                while ( $line{tidbit} =~ /\$someone/i ) {
                    $line{tidbit} =~ s/\$someone/$nicks[rand(@nicks)]/i;
                }
            }
            if ( $line{verb} eq '<reply>' ) {
                $irc->yield( privmsg => $bag{chl} => $line{tidbit} );
            } elsif ( $line{verb} eq '\'s' ) {
                $irc->yield(
                    privmsg => $bag{chl} => "$bag{msg}'s $line{tidbit}" );
            } elsif ( $line{verb} eq '<action>' ) {
                $irc->yield( ctcp => $bag{chl} => "ACTION $line{tidbit}" );
            } else {
                if ( lc $bag{msg} eq 'bucket' and lc $line{verb} eq 'is' ) {
                    $bag{msg}   = 'I';
                    $line{verb} = 'am';
                }
                $irc->yield( privmsg => $bag{chl} =>
                      "$bag{msg} $line{verb} $line{tidbit}" );
            }
            return;
        } elsif ( $bag{msg} =~ s/^what is |^what's |^the //i ) {
            $_[KERNEL]->post(
                db  => 'SINGLE',
                SQL => 'select fact, verb, tidbit from bucket_facts 
                                where fact = ? order by rand('
                  . int( rand(1e6) ) 
                  . ') limit 1',
                PLACEHOLDERS => [ $bag{msg} ],
                BAGGAGE      => {%bag},
                EVENT        => 'db_success'
            );
            return;
        }

        if (
                $bag{editable}
            and $bag{addressed}
            and (  $bag{orig} =~ /(.*?) (?:is ?|are ?)(<\w+>)\s*(.*)/i
                or $bag{orig} =~ /(.*?)\s+(<\w+>)\s*(.*)/
                or $bag{orig} =~ /(.*?)(<'s>)\s+(.*)/i
                or $bag{orig} =~ /(.*?)\s+(is(?: also)?|are)\s+(.*)/i )
          )
        {
            my ( $fact, $verb, $tidbit ) = ( $1, $2, $3 );

            if ( not $bag{addressed} and $fact =~ /^[^a-zA-Z]*<.?\S+>/ ) {
                Log "Not learning from what seems to be an IRC quote: $fact";

                # don't learn from IRC quotes
                return;
            }

            if ( $fact eq 'you' and $verb eq 'are' ) {
                $fact = "Bucket";
                $verb = "is";
            } elsif ( $fact eq 'I' and $verb eq 'am' ) {
                $fact = $bag{who};
                $verb = "is";
            }

            if ( $fact eq $bag{who} ) {
                Log "Not allowing $bag{who} to edit his own factoid";
                $irc->yield( privmsg => $bag{chl} =>
                      "Please don't edit your own factoid, $bag{who}." );
                return;
            }

            $stats{learn}++;
            my $also = 0;
            if ( $tidbit =~ s/^<(action|reply)>\s*// ) {
                $verb = "<$1>";
            } elsif ( $verb eq 'is also' ) {
                $also = 1;
                $verb = 'is';
            } elsif ( $verb =~ /^</ and $verb =~ />$/ ) {
                $bag{forced} = 1;
                if ( $verb ne '<action>' and $verb ne '<reply>' ) {
                    $verb =~ s/^<|>$//g;
                }

                if ( $fact =~ s/ is also$// ) {
                    $also = 1;
                } else {
                    $fact =~ s/ is$//;
                }
            }
            $fact = &trim($fact);

            Log "Learning '$fact' '$verb' '$tidbit'";
            $_[KERNEL]->post(
                db  => 'SINGLE',
                SQL => 'select id, tidbit from bucket_facts 
                        where fact = ? and verb = "<alias>"',
                PLACEHOLDERS => [$fact],
                BAGGAGE      => {
                    %bag,
                    fact   => $fact,
                    verb   => $verb,
                    tidbit => $tidbit,
                    cmd    => "unalias",
                },
                EVENT => 'db_success'
            );

            return;
        } elsif ( $bag{addressed} ) {
            &error( $bag{chl}, $bag{who} );
            return;
        }

        #Log "extra work on $bag{msg}";
        if ( $bag{orig} =~ /^say (.*)/i ) {
            my $msg = $1;
            $stats{say}++;
            $msg =~ s/\W+$//;
            $msg .= "!";
            $irc->yield( privmsg => $bag{chl} => ucfirst $msg );
        } elsif ( $bag{orig} =~ /^(?:Do you|Does anyone) know (\w+)/i
            and $1 !~ /who|of|if|why|where|what|when|whose|how/i )
        {
            $stats{hum}++;
            $irc->yield( privmsg => $bag{chl} =>
                  "No, but if you hum a few bars I can fake it" );
        } elsif ( $bag{orig} =~ s/(\w+)-ass (\w+)/$1 ass-$2/ ) {
            $stats{ass}++;
            $irc->yield( privmsg => $bag{chl} => $bag{orig} );
        } elsif (
            $bag{orig} !~ /extra|except/
            and rand(1) < 0.05
            and (  $bag{orig} =~ s/\ban ex/a sex/
                or $bag{orig} =~ s/\bex/sex/ )
          )
        {
            $stats{sex}++;
            $irc->yield( privmsg => $bag{chl} => $bag{orig} );
        } else {    # lookup band name!
            if ( $bag{type} eq 'irc_public'
                and rand(100) < $config->{band_name} )
            {
                my $name = $bag{orig};
                my $nicks = join "|", map { "\Q$_" } $irc->nicks();
                $nicks = qr/(?:^|\b)(?:$nicks)(?:\b|$)/i;
                $name =~ s/^$nicks://;
                unless ( $name =~ s/$nicks//g ) {
                    $name =~ s/[^\- \w']+//g;
                    $name =~ s/^\s+|\s+$//g;
                    $name =~ s/\s\s+/ /g;
                    my $stripped_name = $name;
                    $stripped_name =~ s/'//g;
                    my @words = split( ' ', $stripped_name );
                    if (    length $name <= 32
                        and @words == 3
                        and $name !~ /\b[ha]{2,}\b/i )
                    {
                        $_[KERNEL]->post(
                            db  => 'SINGLE',
                            SQL => 'select id from band_names where band = ?',
                            PLACEHOLDERS => [$stripped_name],
                            BAGGAGE      => {
                                %bag,
                                name          => $name,
                                stripped_name => $stripped_name,
                                words         => \@words,
                                cmd           => "band_name",
                            },
                            EVENT => 'db_success'
                        );
                    }
                }
            }
        }
    } elsif ( $bag{cmd} eq 'band_name' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        unless ( $line{id} ) {
            my @words = sort { length $b <=> length $a } @{ $bag{words} };
            $_[KERNEL]->post(
                db  => 'SINGLE',
                SQL => 'select id from `mainlog` where 
                            instr( msg, ? ) >0 and 
                            instr( msg, ? ) >0 and 
                            instr( msg, ? ) >0
                            limit 1',
                PLACEHOLDERS => \@words,
                BAGGAGE      => { %bag, cmd => "band_name2", },
                EVENT        => 'db_success'
            );
        }
    } elsif ( $bag{cmd} eq 'band_name2' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        unless ( $line{id} ) {
            $_[KERNEL]->post(
                db  => 'DO',
                SQL => 'insert band_names (band)
                        values (?)',
                PLACEHOLDERS => [ $bag{stripped_name} ],
                BAGGAGE      => { %bag, cmd => "new band name" },
                EVENT        => 'db_success'
            );

            $bag{name} =~ s/(^| )(\w)/$1\u$2/g;
            Report $_[KERNEL],
              "Learned a new band name from $bag{who} in $bag{chl}: $bag{name}";
            &cached_reply( $bag{chl}, $bag{who}, $bag{name},
                "band name reply" );
        }
    } elsif ( $bag{cmd} eq 'band_name_suggest' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};

        $irc->yield( privmsg => $bag{chl} => "How about '$line{band}'?" );
    } elsif ( $bag{cmd} eq 'edit' ) {
        my @lines = ref $res->{RESULT} ? @{ $res->{RESULT} } : [];

        unless (@lines) {
            &error( $bag{chl}, $bag{who} );
            return;
        }

        if ( $lines[0]->{protected} and not $bag{op} ) {
            Log "$bag{who}: that factoid is protected";
            $irc->yield( privmsg => $bag{chl} =>
                  "Sorry, $bag{who}, that factoid is protected" );
            return;
        }

        my ( $gflag, $iflag );
        $gflag = $bag{op} and $bag{flag} =~ s/g//g;
        $iflag = ( $bag{flag} =~ s/i//g ? "i" : "" );
        my $count = 0;
        $undo{ $bag{chl} } =
          [ 'edit', [], "$bag{fact} =~ s/$bag{old}/$bag{new}/" ];

        foreach my $line (@lines) {
            $bag{old} =~ s{\\/}{/}g;
            my $fact = "$line->{verb} $line->{tidbit}";
            $fact = "$line->{verb} $line->{tidbit}" if $line->{verb} =~ /<.*>/;
            if ($gflag) {
                my $c;
                next unless $c = $fact =~ s/(?$iflag:\Q$bag{old}\E)/$bag{new}/g;
                $count += $c;
            } else {
                next unless $fact =~ s/(?$iflag:\Q$bag{old}\E)/$bag{new}/;
            }

            if ( $fact =~ /\S/ ) {
                $stats{edited}++;
                Report $_[KERNEL], "$bag{who} edited $bag{fact}($line->{id})"
                  . " in $bag{chl}: New values: $fact";
                Log
                  "$bag{who} edited $bag{fact}($line->{id}): New values: $fact";
                my ( $verb, $tidbit );
                if ( $fact =~ /^<(\w+)>\s*(.*)/ ) {
                    ( $verb, $tidbit ) = ( "<$1>", $2 );
                } else {
                    ( $verb, $tidbit ) = split ' ', $fact, 2;
                }
                $_[KERNEL]->post(
                    db  => "DO",
                    SQL => 'update bucket_facts set verb=?, tidbit=?
                            where id=? limit 1',
                    PLACEHOLDERS => [ $verb, $tidbit, $line->{id} ],
                    EVENT        => "db_success",
                );
                push @{ $undo{ $bag{chl} }[1] },
                  [ 'update', $line->{id}, $line->{verb}, $line->{tidbit} ];
            } elsif ( $bag{op} ) {
                $stats{deleted}++;
                Report $_[KERNEL], "$bag{who} deleted $bag{fact}($line->{id})"
                  . " in $bag{chl}: $line->{verb} $line->{tidbit}";
                Log "$bag{who} deleted $bag{fact}($line->{id}):"
                  . " $line->{verb} $line->{tidbit}";
                $_[KERNEL]->post(
                    db  => "DO",
                    SQL => 'delete from bucket_facts where id=? limit 1',
                    PLACEHOLDERS => [ $line->{id} ],
                    EVENT        => "db_success",
                );
                push @{ $undo{ $bag{chl} }[1] }, [ 'insert', {%$line} ];
            } else {
                &error( $bag{chl}, $bag{who} );
                Log "$bag{who}: $bag{fact} =~ s/// failed";
            }

            if ($gflag) {
                next;
            }
            $irc->yield(
                privmsg => $bag{chl} => "Okay, $bag{who}, factoid updated." );
            return;
        }

        if ($gflag) {
            if ( $count == 1 ) {
                $count = "one match";
            } else {
                $count .= " matches";
            }
            $irc->yield( privmsg => $bag{chl} => "Okay, $bag{who}; $count." );
            return;
        }

        &error( $bag{chl}, $bag{who} );
        Log "$bag{who}: $bag{fact} =~ s/// failed";
    } elsif ( $bag{cmd} eq 'forget' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        unless ( keys %line ) {
            &error( $bag{chl}, $bag{who} );
            Log "Nothing to forget in '$bag{id}'";
            return;
        }

        $undo{ $bag{chl} } = [ 'insert', \%line ];
        Report $_[KERNEL], "$bag{who} called forget to delete "
          . "'$line{fact}', '$line{verb}', '$line{tidbit}'";
        Log "forgetting $bag{fact}";
        $_[KERNEL]->post(
            db           => "DO",
            SQL          => 'delete from bucket_facts where id=?',
            PLACEHOLDERS => [ $line{id} ],
            EVENT        => "db_success",
        );
        $irc->yield(
            privmsg => $bag{chl} => "Okay, $bag{who}, forgot that",
            "$line{fact} $line{verb} $line{tidbit}"
        );
    } elsif ( $bag{cmd} eq 'delete' ) {
        my @lines = ref $res->{RESULT} ? @{ $res->{RESULT} } : ();
        unless (@lines) {
            &error( $bag{chl}, $bag{who} );
            Log "Nothing to delete in '$bag{fact}'";
            return;
        }

        $undo{ $bag{chl} } = [ 'insert', \@lines, $bag{fact} ];
        Report $_[KERNEL], "$bag{who} deleted '$bag{fact}' in $bag{chl}";
        Log "deleting $bag{fact}";
        $_[KERNEL]->post(
            db           => "DO",
            SQL          => 'delete from bucket_facts where fact=?',
            PLACEHOLDERS => [ $bag{fact} ],
            EVENT        => "db_success",
        );
        my $s = "";
        $s = "s" unless @lines == 1;
        $irc->yield( privmsg => $bag{chl} => "Okay, $bag{who}, "
              . scalar @lines
              . " factoid$s deleted." );
    } elsif ( $bag{cmd} eq 'unalias' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        my $fact = $bag{fact};
        if ( $line{id} ) {
            Log "Dealiased $fact => $line{tidbit}";
            $fact = $line{tidbit};
        }

        $_[KERNEL]->post(
            db  => 'SINGLE',
            SQL => 'select id from bucket_facts where fact = ? and tidbit = ?',
            PLACEHOLDERS => [ $fact, $bag{tidbit} ],
            BAGGAGE      => {
                %bag,
                fact => $fact,
                cmd  => "learn1",
            },
            EVENT => 'db_success'
        );
    } elsif ( $bag{cmd} eq 'learn1' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        if ( $line{id} ) {
            $irc->yield( privmsg => $bag{chl} =>
                  "$bag{who}: I already had it that way" );
            return;
        }

        $_[KERNEL]->post(
            db           => 'SINGLE',
            SQL          => 'select protected from bucket_facts where fact = ?',
            PLACEHOLDERS => [ $bag{fact} ],
            BAGGAGE      => { %bag, cmd => "learn2", },
            EVENT        => 'db_success'
        );
    } elsif ( $bag{cmd} eq 'learn2' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        if ( $line{protected} ) {
            if ( $bag{op} ) {
                unless ( $bag{forced} ) {
                    Log "$bag{who}: that factoid is protected (op, not forced)";
                    $irc->yield( privmsg => $bag{chl} =>
                            "Sorry, $bag{who}, that factoid is protected.  "
                          . "Use <$bag{verb}> to override." );
                    return;
                }

                Log "$bag{who}: overriding protection.";
            } else {
                Log "$bag{who}: that factoid is protected";
                $irc->yield( privmsg => $bag{chl} =>
                      "Sorry, $bag{who}, that factoid is protected" );
                return;
            }
        }

        # we said 'is also' but we didn't get any existing results
        if ( $bag{also} and $res->{RESULT} ) {
            delete $bag{also};
        }

        Report $_[KERNEL], "$bag{who} taught in $bag{chl}:"
          . " '$bag{fact}', '$bag{verb}', '$bag{tidbit}'";
        Log "$bag{who} taught '$bag{fact}', '$bag{verb}', '$bag{tidbit}'";
        $_[KERNEL]->post(
            db  => 'DO',
            SQL => 'insert bucket_facts (fact, verb, tidbit, protected)
                    values (?, ?, ?, ?)',
            PLACEHOLDERS =>
              [ $bag{fact}, $bag{verb}, $bag{tidbit}, $line{protected} || 0 ],
            BAGGAGE => { %bag, cmd => "learn3" },
            EVENT   => 'db_success'
        );
    } elsif ( $bag{cmd} eq 'learn3' ) {
        if ( $res->{INSERTID} ) {
            $undo{ $bag{chl} } = [
                'delete', $res->{INSERTID},
                "that '$bag{fact}' is '$bag{tidbit}'"
            ];

            $stats{last_fact}{ $bag{chl} } = $res->{INSERTID};
        }
        if ( $bag{also} ) {
            $irc->yield( privmsg => $bag{chl} =>
                  "Okay, $bag{who} (added as only factoid)." );
        } else {
            $irc->yield( privmsg => $bag{chl} => "Okay, $bag{who}." );
        }
        if ( exists $fcache{ lc $bag{fact} } ) {
            Log "Updating cache for '$bag{fact}'";
            &cache( $_[KERNEL], $bag{fact} );
        }
    } elsif ( $bag{cmd} eq 'alias1' ) {
        my %line = ref $res->{RESULT} ? %{ $res->{RESULT} } : {};
        if ( $line{id} and $line{verb} ne '<alias>' ) {
            $irc->yield( privmsg => $bag{chl} => "Sorry, $bag{who}, "
                  . "there is already a factoid for '$bag{src}'." );
            return;
        }

        Report $_[KERNEL],
          "$bag{who} aliased in $bag{chl} '$bag{src}' to '$bag{dst}'";
        Log "$bag{who} aliased '$bag{src}' to '$bag{dst}'";
        $_[KERNEL]->post(
            db  => 'DO',
            SQL => 'insert bucket_facts (fact, verb, tidbit, protected)
                    values (?, "<alias>", ?, 1)',
            PLACEHOLDERS => [ $bag{src}, $bag{dst} ],
            BAGGAGE =>
              { %bag, fact => $bag{src}, tidbit => $bag{dst}, cmd => "learn3" },
            EVENT => 'db_success'
        );
    } elsif ( $bag{cmd} eq 'cache' ) {
        my @lines = ref $res->{RESULT} ? @{ $res->{RESULT} } : [];
        $fcache{ lc $bag{key} } = [];
        foreach my $line (@lines) {
            $fcache{ lc $bag{key} } = [@lines];
        }
        Log "Cached " . scalar(@lines) . " factoids for $bag{key}";
    } elsif ( $bag{cmd} eq 'literal' ) {
        my @lines = ref $res->{RESULT} ? @{ $res->{RESULT} } : [];

        unless (@lines) {
            &error( $bag{chl}, $bag{who}, "$bag{who}: " );
            return;
        }

        my $prefix = "$bag{fact}";
        if ( $lines[0]->{protected} ) {
            $prefix .= " (protected)";
        }

        my $answer;
        my $linelen = 400;
        while ( $bag{page}-- ) {
            $answer = "";
            while ( my $fact = shift @lines ) {
                my $bit = "$fact->{verb} $fact->{tidbit}";
                $bit =~ s/\|/\\|/g;
                if ( length( $answer . $bit ) > $linelen and $answer ) {
                    unshift @lines, $fact;
                    last;
                }
                if ( $fact->{chance} ) {
                    $bit .= "[$fact->{chance}%]";
                }
                if ( $fact->{mood} ) {
                    my @moods = ( ":<", ":(", ":|", ":)", ":D" );
                    $bit .= "{$moods[$fact->{mood}/20]}";
                }

                $answer = join "|", ( $answer ? $answer : () ), $bit;
            }
        }

        if (@lines) {
            $answer .= "|" . @lines . " more";
        }
        $irc->yield( privmsg => $bag{chl} => "$prefix $answer" );
    } elsif ( $bag{cmd} eq 'stats1' ) {
        $stats{triggers} = $res->{RESULT}{c};
    } elsif ( $bag{cmd} eq 'stats2' ) {
        $stats{rows} = $res->{RESULT}{c};
    } else {
        Log "DB returned.",
          "Query: $res->{QUERY}, Result: $res->{RESULT}, Bags: $res->{BAGGAGE}";
    }
}

sub irc_start {
    Log "DB Connect...";
    $_[KERNEL]->post(
        db       => 'CONNECT',
        DSN      => $config->{db_dsn},
        USERNAME => $config->{db_username},
        PASSWORD => $config->{db_password},
        EVENT    => 'db_success',
    );

    $irc->yield( register => 'all' );
    $_[HEAP]->{connector} = POE::Component::IRC::Plugin::Connector->new();
    $irc->plugin_add( Connector => $_[HEAP]->{connector} );

    &cache( $_[KERNEL], "Don't know" );
    &cache( $_[KERNEL], "band name reply" );

    $irc->yield(
        connect => {
            Nick     => $nick,
            Username => $config->{username} || "bucket",
            Ircname  => $config->{irc_name} || "YABI",
            Server   => $config->{server} || "irc.foonetic.net",
            Flood    => 0,
        }
    );

    $_[KERNEL]->delay( check_idle => 60 );

    if ( -f $config->{bucketlog} and open BLOG, $config->{bucketlog} ) {
        seek BLOG, 0, SEEK_END;
    }
}

sub irc_on_notice {
    my ($who) = split /!/, $_[ARG0];
    my $msg = $_[ARG2];

    Log("Notice from $who: $msg");
    if (    $who eq 'NickServ'
        and $msg =~ /Password accepted|isn't registered/ )
    {
        $irc->yield( join => $channel );
        unless (DEBUG) {
            Log("Autojoining channels");
            foreach
              my $chl ( $config->{logchannel}, keys %{ $config->{autojoin} } )
            {
                $irc->yield( join => $chl );
                Log("... $chl");
            }
        }
    }
}

sub irc_on_connect {
    Log("Connected...");
    Log("Identifying...");
    $irc->yield( privmsg => nickserv => "identify $pass" );
    Log("Done.");
}

sub irc_on_disconnect {
    Log("Disconnected...");
    close LOG;
    $irc->call( unregister => 'all' );
    exit;
}

sub save {
    DumpFile( $configfile, $config );
}

sub error {
    my ( $chl, $who, $prefix ) = @_;
    &cached_reply( $chl, $who, $prefix, "don't know" );
}

sub cached_reply {
    my ( $chl, $who, $extra, $type ) = @_;
    my $line = $fcache{$type}[ rand( @{ $fcache{$type} } ) ];
    Log "cached '$type' reply: $line->{verb} $line->{tidbit}";

    my $tidbit = $line->{tidbit};
    $tidbit =~ s/\$who/$who/gi;
    if ( $tidbit =~ /\$someone/i ) {
        my @nicks = $irc->nicks();
        while ( $tidbit =~ /\$someone/i ) {
            $tidbit =~ s/\$someone/$nicks[rand(@nicks)]/i;
        }
    }

    if ( $type eq 'band name reply' ) {
        if ( $tidbit =~ /\$band/i ) {
            $tidbit =~ s/\$band/$extra/ig;
        }

        $extra = "";
    }

    if ( $line->{verb} eq '<action>' ) {
        $irc->yield( ctcp => $chl => "ACTION $tidbit" );
    } elsif ( $line->{verb} eq '<reply>' ) {
        $irc->yield( privmsg => $chl => $tidbit );
    } else {
        $extra ||= "";
        $irc->yield( privmsg => $chl => "$extra$tidbit" );
    }
}

sub cache {
    my ( $kernel, $key ) = @_;
    $kernel->post(
        db           => 'MULTIPLE',
        BAGGAGE      => { cmd => "cache", key => $key },
        SQL          => 'select verb, tidbit from bucket_facts where fact = ?',
        PLACEHOLDERS => [$key],
        EVENT        => 'db_success'
    );
}

sub get_stats {
    my ($kernel) = @_;

    Log "Updating stats";
    $kernel->post(
        db      => 'SINGLE',
        BAGGAGE => { cmd => "stats1" },
        SQL     => "select count(distinct fact) c from bucket_facts",
        EVENT   => 'db_success'
    );
    $kernel->post(
        db      => 'SINGLE',
        BAGGAGE => { cmd => "stats2" },
        SQL     => "select count(id) c from bucket_facts",
        EVENT   => 'db_success'
    );

    $stats{last_updated} = time;
}

sub tail {
    my $kernel = shift;

    my $time = 1;
    while (<BLOG>) {
        chomp;
        s/^[\d-]+ [\d:]+ //;
        s/from [\d.]+ //;
        Report $kernel, $time++, $_;
    }
    seek BLOG, 0, SEEK_CUR;
}

sub check_idle {
    $_[KERNEL]->delay( check_idle => 60 );

    my $chl = DEBUG ? $channel : $mainchannel;
    return if time - $last_activity{$chl} < 60 * $config->{random_wait};

    $_[KERNEL]->post(
        db  => 'SINGLE',
        SQL => 'select id, fact, verb, tidbit from bucket_facts 
                        order by rand(' . int( rand(100) ) . ') limit 1 ',
        BAGGAGE => {
            cmd       => "fact",
            chl       => $chl,
            msg       => undef,
            orig      => undef,
            who       => 'Bucket',
            addressed => 0,
            editable  => 0,
            op        => 0,
            type      => 'irc_public',
        },
        EVENT => 'db_success'
    );

    $last_activity{$chl} = time;
}

sub trim {
    my $msg = shift;

    $msg =~ s/[^\w+]+$// if $msg !~ /^[^\w+]+$/;
    $msg =~ s/\\(.)/$1/g;

    return $msg;
}
