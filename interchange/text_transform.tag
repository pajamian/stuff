#
# [text-transform]
# Applies one or more Interchange filters to database fields directly in a table.
#
# Usage: [text transform table field filters]
# table: table to apply filter to
# field: field to apply filter to
# filters: space separated list of interchange filters to apply
#
# Additional attributes:
# column: column to narrow fields on, defaults to the key column
# op: can be any SQL operator or an Interchange or perl operator limited to the following:
#	== eq = > gt >= ge < lt <= le != ne <>
#	defaults to =
# value: value to compare to if left blank (and there's no where attribute) then all rows will be modified
# where: direct sql WHERE clause to apply (overrides column, op and value, beware of SQL injection attacks!)
#
# Returns the number of rows changed on success (unless the hide global attribute is set) or undef on failure.
#
# Known Issues: This tag does not work with tables that use a composite key.
#
UserTag text-transform Order table field filters
UserTag text-transform AddAttr
UserTag text-transform Routine <<EOR
sub {
	# Accepted operators to SQL operator map
	my %op_map = qw{
		=	=
		==	=
		eq	=
		>	>
		gt	>
		>=	>=
		ge	>=
		<	<
		lt	<
		<=	<=
		le	<=
		<>	<>
		!=	<>
		ne	<>
	};

	my ($table, $field, $filters, $opt) = @_;
	my ($column, $op, $value, $where) = @{$opt}{qw{column op value where}};

	my $db = database_exists_ref($table) or do {
		::logError("text-transform: Can't open table $table");
		return;
	};
	my $dbh = $db->dbh();

	# We want to do our own error handling and not have ungraceful 500 pages
	local $dbh->{RaiseError};
	local $dbh->{PrintError};
#::logError("text-transform 1: table=$table\n" . ::uneval($db->[0]));

	# Get the proper table name and quote it.
	$table = $dbh->quote_identifier($db->config('name'));
#::logError("text-transform 2: table=$table");

	unless ($db->column_exists($field)) {
		::logError("text-transform: column $field does not exist in $table");
		return;
	}
	$field = $dbh->quote_identifier($field);

	unless ($filters) {
		::logError("text-transform: No filters to apply!");
		return;
	}

	if (!$where && $value) {
		$value = $db->quote($value);

		$op = $op ? $op_map{$op} : '=' or do {
			::logError("text-transform: Invalid op $opt->{op}");
			return;
		};

		if ($column && !$db->column_exists($column)) {
			::logError("text-transform: column $column does not exist in $table");
			return;
		}
		$column ||= $db->config('KEY');
		$column = $dbh->quote_identifier($column);

		$where = "$column $op $value";
	}

	$where = $where ? "WHERE $where" : '';

	my $key = $dbh->quote_identifier($db->config('KEY'));

	my $read_sql = "SELECT $key, $field FROM $table $where";
#::logError("text-transform: $read_sql");
	my $read_sth = $dbh->prepare($read_sql);
	if ($dbh->err()) {
		my $err = $dbh->errstr();
		::logError("text-transform: Error preparing query: $read_sql\n$err");
		return;
	}

	my $write_sql = "UPDATE $table SET $field = ? WHERE $key = ?";
	my $write_sth = $dbh->prepare($write_sql);
	if ($dbh->err()) {
		my $err = $dbh->errstr();
		::logError("text-transform: Error preparing query: $write_sql\n$err");
		return;
	}

	$read_sth->execute();
	if ($read_sth->err()) {
		my $err = $read_sth->errstr();
		::logError("text-transform: Error executing query: $read_sql\n$err");
		return;
	}

	my $count = 0;
	while (my ($code, $val) = $read_sth->fetchrow_array()) {
		my $newval = Vend::Interpolate::filter_value($filters, $val);
		# Avoid hitting the db if the filters didn't change anything
		next if ($newval eq $val);

		# Update the value in the table
		$write_sth->execute($newval, $code);
		if ($write_sth->err()) {
			my $err = $write_sth->errstr();
			::logError("text-transform: Error updating table $table with value $value: $write_sql\n$err");
			return;
		}
		$count++;
	}
	if ($read_sth->err()) {
		my $err = $read_sth->errstr();
		::logError("text-transform: Error fetching from: $read_sql\n$err");
		return;
	}

	return $count;
}
EOR
