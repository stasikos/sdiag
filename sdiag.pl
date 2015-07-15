#!/usr/bin/perl -w

# Copyright (C) 2015 Stanislav Kogut <stasikos@gmail.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

use strict;
use warnings;
use utf8;
use feature 'unicode_strings';
use Data::Dumper;
use Imager;

sub sign {
    my $a = shift;
    if ( $a > 0 ) {
        return 1;
    }
    elsif ( $a < 0 ) {
        return -1;
    }
    else {
        return 0;
    }
}

# Some configuration :)
my $text_line_regex = '\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] <(.*?)> (.*)$'
  ;    # First group is expected to be nick; second is the text
my $nick_change_regex =
  '\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] Nick change: (.*) -> (.*)$';

# Leave/join can be used to detect same nick after change and rejoin
my $nick_lj_regex =
  '\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] (.*?) \((.*?)\) (left|joined).*'
  ;    # $1 is nick, $2 is ident/host
  
my $max_indirect_mentions = 5;
  
binmode STDOUT, ':encoding(UTF8)';

my %all_nodes;

my $file = $ARGV[0];
die 'No filename given' if ( !$file );

# At first scan for nicknames. It leads to double file reading, but I have no clue to solve this other way.
# "Bots" making this by getting names from channel
my $FH;
open( $FH, '<:encoding(UTF8)', $file ) or die "Can't open file $file, $!";

sub find_by_ident {
    my $i = shift;
    foreach my $nick ( keys %all_nodes ) {
        my $n = $all_nodes{$nick};

        my $id = $n->{'ident'};
        if ( $id && $id eq $i ) {
            return $n;
        }
    }
}

# TODO: add some other ways to find mentions, like "messages by same nick after mention is mention too" and so on.
# TODO: improve ident/host detection in case of dynamic IP
while ( my $line = <$FH> ) {
    chomp $line;
    if ( $line =~ m/$nick_lj_regex/ ) {
        my $nick  = $1;
        my $ident = $2;
        my $n     = $all_nodes{$nick};
        if ( !$n ) {
            $n = find_by_ident($ident);
            if ( !$n ) {
                # Just make new node and remember ident
                $all_nodes{$nick}{'ident'} = $ident;
                $all_nodes{$nick}{'nick'}  = $nick;
            }
            else {
                # node with this ident exists - add nick as alias
                my $aliases = $n->{'aliases'};
                push @$aliases, $nick;
                $n->{'aliases'}              = $aliases;
                $all_nodes{$nick}{'ident'}   = $ident;
                $all_nodes{$nick}{'oldnick'} = $n->{'nick'};
                $all_nodes{$nick}{'nick'}    = $nick;
            }
        }
        else {
            # node exists - save ident
            $n->{'ident'} = $ident;
        }
    }
    if ( $line =~ m/$nick_change_regex/ ) {
        my $old = $1;
        my $new = $2;

        my $nick_node = $all_nodes{$1};
        my $aliases   = $nick_node->{'aliases'};
        push @$aliases, $new;
        $all_nodes{$old}->{'nick'}    = $old;
        $all_nodes{$old}->{'aliases'} = $aliases;
        if ( !$all_nodes{$new} ) {
            $all_nodes{$new}->{'nick'}    = $new;
            $all_nodes{$new}->{'oldnick'} = $old;
        }
    }
    elsif ( $line =~ m/$text_line_regex/ ) {
        my $a_nick = $1;
        $all_nodes{$a_nick}->{'message_count'}++;
        $all_nodes{$a_nick}->{'nick'} = $a_nick;
    }
}
close $FH;

# second pass: find any relations between nicks, using above list as known nicks
open( $FH, '<:encoding(UTF8)', $file ) or die "Can't open file $file, $!";

my $passed = 0;
my $last_mentioned;
my $last_nick;

while ( my $line = <$FH> ) {
    chomp $line;
    my $found;
    $passed++;    
    if ( $line =~ m/$text_line_regex/ ) {
        my $a_nick = $1;
        my $text   = $2;
        for my $nick ( keys %all_nodes ) {
            if ( $text =~ m/\Q$nick\E/ ) {
                $all_nodes{$a_nick}->{'mentions'}{$nick}++;
                $found = 1;
                $passed = 0;
                $last_nick = $a_nick;
                $last_mentioned = $nick;
            }
        }
    }
    if (!$found && $last_mentioned && $passed < $max_indirect_mentions) {
        $all_nodes{$last_nick}->{'mentions'}{$last_mentioned}++;
    }
}
close $FH;

# Reduce nicks to their "originals", megre mentions
foreach my $nick ( keys %all_nodes ) {
    my $n = $all_nodes{$nick};

    my $mentions = $n->{'mentions'};
    if ($mentions) {
        my %mhash = %{$mentions};
        foreach my $m ( keys %mhash ) {

            # Get mentioned node
            my $mentioned = $all_nodes{$m};

            # Check if it is new nick
            my $oldnick = $mentioned->{'oldnick'};
            if ($oldnick) {

                # add mentions count to old nick and delete new
                $mhash{$oldnick} += $mhash{$m};
                $mhash{$m} = 0;
                delete $mhash{$m};
            }
        }
        $n->{'mentions'} = \%mhash;
    }
}

# Iterate over all nodes/nicks and merge aliases with first used nick
foreach my $nick ( keys %all_nodes ) {
    my $n       = $all_nodes{$nick};
    my $aliases = $n->{'aliases'};
    if ($aliases) {
        my @aarray = @{$aliases};
        foreach my $a (@aarray) {
            my $an = $all_nodes{$a};
            if ($an) {
                $n->{'message_count'} += ( $an->{'message_count'} // 0 );

                # Copy mentions
                for my $m ( keys %{ $an->{'mentions'} } ) {
                    $n->{'mentions'}{$m} += ( $an->{'mentions'}{$m} // 0 );
                }

            }
            delete $all_nodes{$a};
        }
    }
}

# Some housekeeping
foreach my $nick ( keys %all_nodes ) {
    my $n = $all_nodes{$nick};

    if ( !$n->{'nick'} ) {
        print "No nick in $nick node\n";
        $n->{'nick'} = $nick;
    }

    if ( !$n->{'message_count'} ) {
        $n->{'message_count'} = 0;
    }
    if ( $n->{'message_count'} < 2 ) {
        delete $all_nodes{$nick};
    }
}

# Fill in edges - links between nodes;

foreach my $nick ( keys %all_nodes ) {
    my $n        = $all_nodes{$nick};
    my $mentions = $n->{'mentions'};
    my @edges;
    if ($mentions) {
        for my $m ( keys %$mentions ) {
            my %edge = (
                weight_s => $mentions->{$m},
                weight_t => $all_nodes{$m}{'mentions'}{$nick},
                t        => $m,
                s        => $nick,
            );
            push @edges, \%edge;
        }
    }
    $n->{'edges'} = \@edges;
}

#
# Draw diagram
#
use GD::Simple;

my $iw  = 800;
my $ih  = 600;
my $img = GD::Simple->new( $iw, $ih );
$img->bgcolor('yellow');
$img->fgcolor('blue');

# using same algo as piespy

my @edges;

foreach my $nick ( keys %all_nodes ) {
    my $n = $all_nodes{$nick};
    foreach my $e ( @{ $all_nodes{$nick}{'edges'} } ) {
        my %edge = (
            s      => $nick,
            t      => $e->{'t'},
            weight => $e->{'weight_s'} // 0 + $e->{'weigth_t'} // 0
        );
        push @edges, \%edge;
    }
}

my $maxRDist   = 10;
my $k          = 2;
my $c          = 0.03;
my $maxM       = 0.5;
my $iterations = 100;

for ( my $i = 0 ; $i < $iterations ; $i++ ) {
    foreach my $nick ( keys %all_nodes ) {
        foreach my $nick2 ( keys %all_nodes ) {
            my $n1 = $all_nodes{$nick};
            my $n2 = $all_nodes{$nick2};
            my $dX =
              ( $n2->{'x'} // ( rand() * 2 ) ) -
              ( $n1->{'x'} // ( rand() * 2 ) );
            my $dY =
              ( $n2->{'y'} // ( rand() * 2 ) ) -
              ( $n1->{'y'} // ( rand() * 2 ) );
            my $dSquared = $dX * $dX + $dY * $dY;
            if ( $dSquared < 0.01 ) {
                $dX       = rand() / 10 + 0.1;
                $dY       = rand() / 10 + 0.1;
                $dSquared = $dX * $dX + $dY * $dY;
            }
            my $dist = sqrt($dSquared);
            if ( $dist < $maxRDist ) {
                my $rForce = ( $k * $k / $dist );
                $n1->{'fx'} = ( $n1->{'fx'} // 0 ) - ( $rForce * $dX / $dist );
                $n1->{'fy'} = ( $n1->{'fy'} // 0 ) - ( $rForce * $dY / $dist );
                $n2->{'fx'} = ( $n2->{'fx'} // 0 ) + ( $rForce * $dX / $dist );
                $n2->{'fy'} = ( $n2->{'fy'} // 0 ) + ( $rForce * $dY / $dist );
            }
        }
    }

    foreach my $e (@edges) {
        my $n1 = $all_nodes{ $e->{'s'} };
        my $n2 = $all_nodes{ $e->{'t'} };
        my $dX =
          ( $n2->{'x'} // ( rand() * 2 ) ) - ( $n1->{'x'} // ( rand() * 2 ) );
        my $dY =
          ( $n2->{'y'} // ( rand() * 2 ) ) - ( $n1->{'y'} // ( rand() * 2 ) );
        my $dSquared = $dX * $dX + $dY * $dY;
        if ( $dSquared < 0.01 ) {
            $dX       = rand() / 10 + 0.1;
            $dY       = rand() / 10 + 0.1;
            $dSquared = $dX * $dX + $dY * $dY;
        }
        my $dist = sqrt($dSquared);
        if ( $dist > $maxRDist ) {
            $dist = $maxRDist;
        }
        $dSquared = $dist * $dist;
        my $weight = $e->{'weight'};
        my $aForce = ( $dSquared - $k * $k ) / $k;
        if ( $weight < 1 ) {
            $weight = 1;
        }

        $aForce *= ( log($weight) * 0.5 ) + 1;

        $n1->{'fx'} = $n1->{'fx'} + $aForce * $dX / $dist;
        $n1->{'fy'} = $n1->{'fy'} + $aForce * $dY / $dist;
        $n2->{'fx'} = $n2->{'fx'} - $aForce * $dX / $dist;
        $n2->{'fy'} = $n2->{'fy'} - $aForce * $dY / $dist;

    }

    for my $nick ( keys %all_nodes ) {
        my $n   = $all_nodes{$nick};
        my $mX  = $c * $n->{'fx'};
        my $mY  = $c * $n->{'fy'};
        my $max = $maxM;
        if ( abs($mX) > abs($max) ) {
            $mX = $max * sign($mX);
        }
        if ( abs($mY) > abs($max) ) {
            $mY = $max * sign($mY);
        }
        $n->{'x'} += $mX;
        $n->{'y'} += $mY;
        $n->{'fx'} = 0;
        $n->{'fy'} = 0;
    }
}

#Draw image.
my $eT      = 1;
my $minX    = 2**53;
my $minY    = 2**53;
my $maxX    = -2**53;
my $maxY    = -2**53;
my $minSize = 10;
my $bs      = 50;

#calc bounds
foreach my $nick ( keys %all_nodes ) {
    my $n = $all_nodes{$nick};

    # Possible refactoring to 2 subs, but found no word to name it :)
    if ( $n->{'x'} > $maxX ) {
        $maxX = $n->{'x'};
    }
    if ( $n->{'y'} > $maxY ) {
        $maxY = $n->{'y'};
    }
    if ( $n->{'x'} < $minX ) {
        $minX = $n->{'x'};
    }
    if ( $n->{'y'} < $minY ) {
        $minY = $n->{'y'};
    }
    if ( $maxX - $minX < $minSize ) {
        my $mid = ( $maxX + $minX ) / 2;
        $minX = $mid - ( $minSize / 2 );
        $maxX = $mid + ( $minSize / 2 );
    }
    if ( $maxY - $minY < $minSize ) {
        my $mid = ( $maxY + $minY ) / 2;
        $minY = $mid - ( $minSize / 2 );
        $maxY = $mid + ( $minSize / 2 );
    }
    my $r = ( ( $maxX - $minX ) / ( $maxY - $minY ) ) / ( $iw / $ih );
    if ( $r > 1 ) {
        my $dy = $maxY - $minY;
        $dy   = $dy * $r - $dy;
        $minY = $minY - $dy / 2;
        $maxY = $maxY + $dy / 2;
    }
    elsif ( $r < 1 ) {
        my $dx = $maxX - $minX;
        $dx   = $dx * $r - $dx;
        $minX = $minY - $dx / 2;
        $maxX = $maxY + $dx / 2;
    }

}

# draw edges
# TODO: maybe make edge thicker/thinner depending on mentions count
EDGE: foreach my $e (@edges) {
    my $w = $e->{'weight'};
    if ( $w < $eT ) {
        next EDGE;
    }
    my $n1 = $all_nodes{ $e->{'s'} };
    my $n2 = $all_nodes{ $e->{'t'} };
    my $x1 = ( $iw * ( $n1->{'x'} - $minX ) / ( $maxX - $minX ) ) + $bs;
    my $y1 = ( $ih * ( $n1->{'y'} - $minY ) / ( $maxY - $minY ) ) + $bs;
    my $x2 = ( $iw * ( $n2->{'x'} - $minX ) / ( $maxX - $minX ) ) + $bs;
    my $y2 = ( $ih * ( $n2->{'y'} - $minY ) / ( $maxY - $minY ) ) + $bs;

    $img->fgcolor('blue');

    #       $img->penSize($w, $w);
    $img->moveTo( $x1, $y1 );
    $img->lineTo( $x2, $y2 );
}

# draw nodes
# TOOD: move all colors to some "configuration" place
foreach my $nick ( keys %all_nodes ) {
    my $n  = $all_nodes{$nick};
    my $x1 = ( $iw * ( $n->{'x'} - $minX ) / ( $maxX - $minX ) ) + $bs;
    my $y1 = ( $ih * ( $n->{'y'} - $minY ) / ( $maxY - $minY ) ) + $bs;

# It will look like everyone has at least one message, and I assume it is not bad
    my $nr = log( $n->{'message_count'} // 1 ) * 5;
    $img->bgcolor('yellow');
    $img->fgcolor('blue');
    $img->moveTo( $x1, $y1 );
    $img->ellipse( $nr, $nr );
    $img->fgcolor('red');
    $img->moveTo( $x1 + sqrt($nr), $y1 - sqrt($nr) );
    $img->string($nick);

}

my $IMG;
open $IMG, '>', 'output.png' or die "$!";

print $IMG $img->png;
close $IMG;
