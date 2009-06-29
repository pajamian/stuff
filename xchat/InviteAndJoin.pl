package Xchat::PJ::InviteAndJoin;

#use Data::Dumper;

# Waits for nickserv to identify then requests invites
# to a list of channels you specify (below).  Joins
# the channel once the invite is recieved.

# channels you want to join (lowercase)
# and their keys, if any
my %channels = (
    '#interchange-core'=>'',
);

## NO NEED TO MODIFY BELOW THIS POINT ##
########################################

my $NAME    = 'Invite and Join';
my $VERSION = '001';
my $PREFIX  = "\002INVITE AND JOIN\002";

Xchat::register($NAME, $VERSION, 
	"Joins a channel you're invited to, if it's on the list.");
Xchat::print("\02$NAME $VERSION\02 by pj");
my $invhook = Xchat::hook_print('Invited', \&invited);
my $idhook = Xchat::hook_server('NOTICE', \&identified);

sub identified {
    my ($from, $msg) = ($_[0][0], $_[1][3]);
    return Xchat::EAT_NONE unless
	$from =~ /^:NickServ!/ and
	$msg =~ /^:\+You are now identified for/;

    foreach (keys %channels) {
	Xchat::command("msg chanserv invite $_");
    }

    Xchat::unhook($idhook);
    return Xchat::EAT_NONE;
}

sub invited {
	my @args = @{ $_[0] };
	my $chan = lc shift @args;

	if( exists $channels{$chan} ) {
		Xchat::print("$PREFIX joining $chan...");
		Xchat::command("join $chan $channels{$chan}");
	}

	delete $channels{$chan};
	if (!%channels) {
	    Xchat::unhook($invhook);
	    Xchat::command('unload InviteAndJoin.pl');
	}

	return Xchat::EAT_NONE;
}

__END__
