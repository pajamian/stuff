# Copyright 2009 Peter Ajamian <peter@pajamian.dhs.org>
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.  See the LICENSE file for details.

# This usertag will return the entire contents concatenated together if all of
# the individual components contain something that is not whitespace.  Example:
#
# Old method:
# foo[if scratch bar] - [scratch bar][/if]
#
# With this usertag:
# foo[both] - [and][scratch bar][/both]
#
# Note the difference that if [scratch bar] contains 0 then [both] will still
# count it as a true value.

UserTag both              hasEndTag
UserTag both              PosNumber    0
UserTag both              NoReparse    1
UserTag both              Routine      <<EOR
sub {
	my @ary = split /\[and\]/, shift;

	foreach (@ary) {
		$_ = interpolate_html($_);
		return unless /\S/;
	}
	return join '', @ary;
}
EOR
