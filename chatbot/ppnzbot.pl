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

use FindBin;
unshift @INC, $FindBin::Bin;
use ChatBotSettings;

use Encode;
use Data::Dumper;
use Time::HiRes ();
use Date::Parse;
use POSIX qw{strftime tzset};
use AnyEvent;
use AnyEvent::IRC::Client;
use AnyEvent::Feed;

# Set the time zone
$ENV{TZ} = 'Pacific/Auckland';
tzset();

my $c = AnyEvent->condvar;

my $host = $ChatBotSettings::Host;
my $port = $ChatBotSettings::Port;
my $info = {
    nick => $ChatBotSettings::Nick,
    user => $ChatBotSettings::Ident,
    real => $ChatBotSettings::RealName,
};

my @channels = map { lc } @ChatBotSettings::Channels;

# Logging
# We call relog when initializing the logs and also whenever we log something new.
# It checks to see if the date has changed and if so it opens new log files under the new date.
my $logdir = $ChatBotSettings::LogDir;
my %log_channels = map {(lc, undef)} @ChatBotSettings::LogChannels;
my $logdate;
sub relog {
    my $today = strftime('%Y%m%d', localtime());
    return unless $logdate && $logdate ne $today;
    $logdate = $today;

    while (my($chan, $fh) = each %log_channels) {
	close $fh if $fh;

	my $path = "$logdir/$chan-$logdate";
	if (open($fh, '>>', $path)) {
	    # Enable autoflush for the filehand
	    my $oldfh = select $fh;
	    $| = 1;
	    select $oldfh;
	    # Return the hash element
	    $log_channels{$chan} = $fh;
	}
	else {
	    print "Error: Can't open $path for write/append logging of channel $chan: $! ... disabling logging for $chan\n";
	    delete $log_channels{$chan};
	}
    }
}
relog();

# Call this with the channel and msg to log stuff.  Automatically prepends a timestamp.
sub logtext {
    relog();
    my ($channel, $msg) = @_;
    $channel = lc $channel;
    return unless $log_channels{$channel};

    my $fh = $log_channels{$channel};
    my $time = strftime('%T', localtime());
    print $fh "[$time] $msg\n"
}

my $con = AnyEvent::IRC::Client->new(send_initial_whois => 1);

# Event callbacks for verious events that log
$con->reg_cb(channel_add => sub {
    my ($self, $msg, $channel, @nicks) = @_;
    logtext $channel, "Joins: @nicks";
	     });

$con->reg_cb(channel_remove => sub {
    my ($self, $msg, $channel, @nicks) = @_;
    logtext $channel, "Parts: @nicks";
	     });

$con->reg_cb(channel_change => sub {
    my ($self, $msg, $channel, $old_nick, $new_nick) = @_;
    logtext $channel, "Nick change: $old_nick -> $new_nick";
	     });

$con->reg_cb(channel_topic => sub {
    my ($self, $channel, $topic, $who) = @_;
    foreach ($who, $topic) { $_ ||= '' }
    logtext $channel, "Topic set by $who: $topic";
	     });

$con->reg_cb(join => sub {
    my ($self, $nick, $channel, $is_myself) = @_;
    return unless $is_myself;
    logtext $channel, "Joined $channel as $nick";
	     });

$con->reg_cb(part => sub {
    my ($self, $nick, $channel, $is_myself) = @_;
    logtext $channel, "Parted $channel";
	     });

$con->reg_cb(ctcp_action => sub {
    my ($self, $nick, $channel, $msg, $type) = @_;
    return unless $type eq 'PRIVMSG';
    return if $self->is_my_nick($channel);
    logtext $channel, "Action: $nick $msg";
	     });

$con->reg_cb(publicmsg => sub {
    my ($self, $channel, $ircmsg) = @_;
    my $msg = $ircmsg->{params}[1];
    my ($nick) = $ircmsg->{prefix} =~ /^(.*?)!/;
    logtext $channel, "<$nick> $msg";
	     });

sub say {
    my ($chan, $msg) = @_;
    $con->send_chan($chan, PRIVMSG => $chan, $msg, {priority => 'normal'});

    if ($ChatBotSettings::LogBot) {
	my $nick = $con->nick();
	logtext $chan, "<$nick> $msg";
    }
}

sub ping {
    my ($self, undef, $nick) = @_;
    my $time = Time::HiRes::time();
    $self->send_srv(PRIVMSG => $nick, "\001PING $time\001", {priority => 'high'});
};

# Public chat command list.  This is a hash that includes the lowecase command name (to match the first word of the msg)
# and a subref to process the command.
my $public_commands = {
    '!test' => sub {
	my ($self, $chan, $nick) = @_;
	say $chan, "$nick: It works!";
    },
    '!ping' => \&ping,
};

# Private message command list ... same as above.
my $private_commands = {
    '!test' => sub {
	my ($self, undef, $nick) = @_;
	$self->send_srv(NOTICE => $nick, "It works!", {priority => 'normal'});
    },
    '!ping' => \&ping,
};

my %feeds = %ChatBotSettings::Feeds;

foreach my $feed (values %feeds) {
    $feed = [$feed, 0];
}

my %feedcmds = map { (lc $_->[0], [$_->[0], undef]) } values %feeds;

sub feed_on_request {
    my ($self, undef, $nick, $cmd, $msg) = @_;
    $cmd =~ s/^!//;

    my ($title, $feed) = @{$feedcmds{$cmd}};

    if (!defined $feed) {
	$self->send_srv(NOTICE => $nick, "Feed for $title not loaded yet.  Please try again later.", {priority => 'normal'});
	return;
    }

    # Find the number of entries to display and grab a slice of the entries array.
    my $numentries = (split /\s+/, $msg, 3)[1] || '';
    $numentries =~ s/\D//g;
    $numentries ||= 3;
    my @entries = @{$feed->{rss}{items}};
    $numentries = scalar @entries if $numentries > scalar @entries;
    @entries = reverse @entries[0..$numentries-1];

#    print Dumper($feed);

    foreach my $entry (@entries) {
	my $link = $entry->{link};
	my $etitle = $entry->{title};
	$etitle =~ s/\s+/ /g;
	my $date = $entry->{pubDate};
	$date = str2time $date;
	$date = strftime('%d %b %I:%M%P', localtime($date));
	my $msg = encode('utf8', "$date: [$title] $etitle @ $link");
	$self->send_srv(PRIVMSG => $nick, $msg, {priority => 'low'});
    }
}

foreach (keys %feedcmds) {
    $public_commands->{"!$_"} = \&feed_on_request;
    $private_commands->{"!$_"} = \&feed_on_request;
}

# Overload the send_msg function to make it pad the messages so that we don't flood the server.
# We also add an optional $opt to the end of the args with a priority option that can be
# "low", "normal" or "high".  High priority messages go out right away, by-passing the queue.
# low priority messages are put in a seperate queue and only go out once all high and normal
# priority messages have been sent.  Default is normal unless we are not registered yet in which
# case it is high (so that registration is not throttled).
{
    package AnyEvent::IRC::Client;
    no warnings qw{redefine};

    my @msg_queue;
    my @low_queue;
    my $old_send_msg = \&send_msg;
    my $timer;
    my $timer_cb = sub {
	if (!(@msg_queue || @low_queue)) {
	    undef $timer;
	    return;
	}
	else {
	    my $args = @msg_queue ? shift @msg_queue : shift @low_queue;
	    $old_send_msg->(@$args) unless !$args;
	    return;
	}
    };

# Check the message queue and send the message if it's empty, otherwise queue it.
    *send_msg = sub {
	my $self = $_[0];
	my $opt = {};
	if (ref $_[-1]) {
		$opt = pop;
	}

	my $priority = $opt->{priority} || ($self->{registered} ? 'normal' : 'high');

	if (!$timer) {
	    $old_send_msg->(@_);
	    $timer = AnyEvent->timer(
				     after => 1,
				     interval => 1,
				     cb => $timer_cb,
				     );
	    return;
	}
	elsif ($priority eq 'high') {
		$old_send_msg->(@_);
		unshift @msg_queue, undef;
	}
	elsif ($priority eq 'low') {
		push @low_queue, [@_];
		return;
	}
	else { # priority is normal
	    push @msg_queue, [@_];
	    return;
	}
    };
}

sub read_feed {
    my ($feed_reader, $new_entries, $feed, $error) = @_;

    if (defined $error) {
	warn "ERROR: $error\n";
	return;
    }

    my $title = $feeds{$feed_reader->url()}[0];

    # Load the feed up for manual command-based retrieval
    $feedcmds{lc $title}[1] = $feed if $feed;

#    print Dumper($feed);

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
	$etitle =~ s/\s+/ /g;

	my $msg = encode('utf8', "[$title] $etitle @ $link");

	foreach my $chan (@channels) {
	    say $chan, $msg;
	}

#	print Dumper($hash, $entry);
    }
}

while (my ($url, $vals) = each %feeds) {
    $vals->[2] = AnyEvent::Feed->new (
			 url      => $url,
			 interval => 300,
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
    $self->send_srv(NOTICE => $src, $msg, {priority => 'normal'});
});

# Debugging
#$con->reg_cb(debug_recv => sub {
#    my ($self, $ircmsg) = @_;
#    print Dumper($ircmsg);
#});

# Connection loop
while (1) {
	# Identify to NickServ:
	$con->send_srv(PRIVMSG => 'NickServ', "IDENTIFY $ChatBotSettings::NSpass", {priority => 'high'});

	# Join channels:
	$con->send_srv(JOIN => join ',', @channels, {priority => 'high'});

	$con->connect ($host, $port, $info);
	$c->wait;
	$con->disconnect;

	sleep 60;
}
