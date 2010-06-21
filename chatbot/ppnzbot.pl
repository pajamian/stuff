#!/usr/bin/perl
#
# PPNZ IRC bot, an IRC bot that parrots RSS feeds as well as other minor tasks.
# Copyright (C) 2010 Peter Ajamian <peter@pajamian.dhs.org>
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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
# USA.
#

use strict;
use warnings;

use Encode;
use Data::Dumper;
use Time::HiRes ();
use AnyEvent;
use AnyEvent::IRC::Client;
use AnyEvent::Feed;

my $c = AnyEvent->condvar;

my $host = 'irc.piratpartiet.se';
my $port = 6667;
my $info = {
    nick => 'kiwi',
    user => 'kiwi',
    real => 'PPNZ bot',
};

no warnings qw{qw};
my @channels = qw{
    #ppnz
    #ppnzsocial
};
use warnings qw{qw};

sub ping {
    my ($self, undef, $nick) = @_;
    my $time = Time::HiRes::time();
    $self->send_srv(PRIVMSG => $nick, "\001PING $time\001");
};

# Public chat command list.  This is a hash that includes the lowecase command name (to match the first word of the msg)
# and a subref to process the command.
my $public_commands = {
    '!test' => sub {
	my ($self, $chan, $nick) = @_;
	$self->send_chan($chan, PRIVMSG => $chan, "$nick: It works!");
    },
    '!ping' => \&ping,
};

# Private message command list ... same as above.
my $private_commands = {
    '!test' => sub {
	my ($self, undef, $nick) = @_;
	$self->send_srv(NOTICE => $nick, "It works!");
    },
    '!ping' => \&ping,
};

my %feeds = qw{
	http://twitter.com/statuses/user_timeline/88316972.rss			Twitter
	http://www.facebook.com/feeds/page.php?format=rss20&id=305641940721	Facebook
};

foreach my $feed (values %feeds) {
    $feed = [$feed, 0];
}

my %feedcmds = map { (lc $_->[0], [$_->[0], undef]) } values %feeds;

sub feed_on_request {
    my ($self, undef, $nick, $cmd) = @_;
    $cmd =~ s/^!//;

    my ($title, $feed) = @{$feedcmds{$cmd}};

    if (!defined $feed) {
	$self->send_srv(NOTICE => $nick, "Feed for $title not loaded yet.  Please try again later.");
	return;
    }

#    print Dumper($feed);

    foreach my $entry (@{$feed->{rss}{items}}) {
	my $link = $entry->{link};
	my $etitle = $entry->{title};
	my $date = $entry->{pubDate};

	my $msg = encode('utf8', "$date: [$title] $etitle @ $link");
	$self->send_srv(PRIVMSG => $nick, $msg);
    }
}

foreach (keys %feedcmds) {
    $public_commands->{"!$_"} = \&feed_on_request;
    $private_commands->{"!$_"} = \&feed_on_request;
}

# Overload the send_msg function to make it pad the messages so that we don't flood the server.
{
    package AnyEvent::IRC::Client;
    no warnings qw{redefine};

    my @msg_queue;
    my $old_send_msg = \&send_msg;
    my $timer;
    my $timer_cb = sub {
	if (!@msg_queue) {
	    undef $timer;
	    return;
	}
	else {
	    my $args = shift @msg_queue;
	    $old_send_msg->(@$args);
	    return;
	}
    };

    *send_msg = sub {
	# Check the message queue and send the message if it's empty, otherwise queue it.
	if (!$timer) {
	    $old_send_msg->(@_);
	    $timer = AnyEvent->timer(
				     after => 1,
				     interval => 1,
				     cb => $timer_cb,
				     );
	    return;
	}
	else {
	    push @msg_queue, [@_];
	    return;
	}
    };
}

my $con = AnyEvent::IRC::Client->new(send_initial_whois => 1);

sub read_feed {
    my ($feed_reader, $new_entries, $feed, $error) = @_;

    if (defined $error) {
	warn "ERROR: $error\n";
	return;
    }

    my $title = $feeds{$feed_reader->url()}[0];

    # Load the feed up for manual command-based retrieval
    $feedcmds{lc $title}[1] = $feed;

    # Skip the first reading so we don't display a bunch of old records.
    if (!$feeds{$feed_reader->url()}[1]) {
	$feeds{$feed_reader->url()}[1] = 1;
	return;
    }

    foreach (@$new_entries) {
	my ($hash, $entry) = @$_;
	# $hash a unique hash describing the $entry
	# $entry is the XML::Feed::Entry object of the new entries
	# since the last fetch.

	my $link = $entry->{entry}{link};
	my $etitle = $entry->{entry}{title};

	my $msg = encode('utf8', "[$title] $etitle @ $link");
	
	foreach my $chan (@channels) {
	    $con->send_chan($chan, PRIVMSG => $chan, $msg);
	}

#	print Dumper($hash, $entry);
    }
}

foreach my $url (keys %feeds) {
    AnyEvent::Feed->new (
			 url      => $url,
			 interval => 30,
			 on_fetch => \&read_feed,
			 );
  }

$con->reg_cb (connect => sub {
    my ($con, $err) = @_;
    if (defined $err) {
	warn "connect error: $err\n";
	return;
    }
});

# Stuff to do when connected:
$con->reg_cb (registered => sub {
    print "I'm in!\n";
});

$con->reg_cb (disconnect => sub { print "I'm out!\n"; $c->broadcast });

# Register a callback for public commands
$con->reg_cb(publicmsg => sub {
    my ($self, $chan, $ircmsg) = @_;
    my $msg = $ircmsg->{params}[1];
    my ($nick) = $ircmsg->{prefix} =~ /^(.*?)!/;
    my ($cmd) = $msg =~ /^(\S*)/;
    $cmd = lc $cmd;

    return unless $public_commands->{$cmd};

    $public_commands->{$cmd}($self, $chan, $nick, $cmd, $msg, $ircmsg);
});

# Register a callback for private messages
$con->reg_cb(privatemsg => sub {
    my ($self, $tonick, $ircmsg) = @_;
    my $msg = $ircmsg->{params}[1];
    my ($nick) = $ircmsg->{prefix} =~ /^(.*?)!/;
    my ($cmd) = $msg =~ /^(\S*)/;
    $cmd = lc $cmd;

    return unless $private_commands->{$cmd};

    $private_commands->{$cmd}($self, $tonick, $nick, $cmd, $msg, $ircmsg);
});

# Process the ping replies
# Doesn't quite work yet, needs some debugging.
$con->reg_cb(ctcp_ping => sub {
    my ($self, $src, $target, $msg, $type) = @_;
    return unless $type eq 'NOTICE';

    my $elapsed = Time::HiRes::time() - $msg;

    $msg = sprintf('Ping time %01.2f seconds', $elapsed);
#    print Dumper($src, $target, $msg, $type, $elapsed);
    $self->send_srv(NOTICE => $src, $msg);
});

# Debugging
#$con->reg_cb(debug_recv => sub {
#    my ($self, $ircmsg) = @_;
#    print Dumper($ircmsg);
#});

# Join channels:
$con->send_srv(JOIN => join ',', @channels);

$con->connect ($host, $port, $info);
$c->wait;
$con->disconnect;
