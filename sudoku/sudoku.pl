#!/usr/bin/perl
#
# Sudoku generator Copyright 2023 by Peter Ajamian <peter@pajamian.dhs.org>
# To generate the sudoku we start with a blank grid and start filling in random
# locations with random numbers while making sure that the grid is still
# solveable.  Once we've generated a full grid we remove one number at a time
# and then check to make sure that there is still only a single solution.
#
use 5.010_000;
use strict;
use warnings;

my $pdf;
BEGIN {
    eval {
	require PDF::Builder;
	$pdf = PDF::Builder->new();
    };
    eval {
	require PDF::API2;
	$pdf = PDF::API2->new();
    } unless $pdf;
    die "Need either PDF::Builder or PDF::API2" unless $pdf;
}

use PDF::Table;

use Clone qw(clone);
use Data::Dumper;

$|=1; # Autoflush

#
# Just a convenience array that transforms a number into it's corresponding
# bit.
#
my @numbit;
for (1..9) { $numbit[$_] = 1 << $_-1 }

#
# Page Size for PDF document.
#
my $page_size = 'A4';

#
# Solving bitmap flags
#
my @flags = qw(
    BLANK
    START
    CHECK
);
my %f;
@f{@flags} = map {1<<$_} (0..$#flags);

#
# Difficulty levels, specified in number of cells to leave filled.  Will not
# return fewer cells than that needed for a unique solution even if the level
# specifies such.
#
my %levels = qw(
    easy    51
    normal  41
    hard    31
    extreme 0
    );
my $difficulty = $ARGV[0] || 'normal';
my $level = $levels{lc $difficulty} // $levels{normal};

my $puzzles = $ARGV[1] || 1;
$puzzles = 1 if $puzzles =~ /\D/;
my $filename = $ARGV[2] // 'sudoku.pdf';

# This gets set when a field is found
my $found_field;

# This gets set to the first found solution.
my $found_grid = 0;

#
# Utility sub to check the return value of certain functions.
#
sub ckretnum {
    my ($r, $v) = @_;
    return '' unless defined($v);
    return !ref($r) && defined($r) && $r == $v;
}

#
# Walk each field in the grid.  Calls the passed sub with $field, $row, $col,
# $grid.  Any non-zero return value from the sub causes the grid to stop being
# walked early and return that value.
#
sub walk_grid {
    my ($grid, $sub) = @_;
    for my $r (0..8) {
	for my $c (0..8) {
	    my $ret = $sub->($grid->[$r][$c], $r, $c, $grid);
	    return $ret if $ret;
	}
    }
    return;
}

#
# Same as above, but walks a single row.
#
sub walk_row {
    my ($grid, $r, $sub) = @_;
    for my $c (0..8) {
	my $ret = $sub->($grid->[$r][$c], $r, $c, $grid);
	return $ret if $ret;
    }
    return;
}

#
# Same again, but walks a single column.
#
sub walk_column {
    my ($grid, $c, $sub) = @_;
    for my $r (0..8) {
	my $ret = $sub->($grid->[$r][$c], $r, $c, $grid);
	return $ret if $ret;
    }
    return;
}

#
# Same but walks the 3x3 block containing the passed row/col coordinates.
#
sub walk_block {
    my ($grid, $r, $c, $sub) = @_;

    my $rs = int($r/3)*3;
    my $re = $rs + 2;
    my $cs = int($c/3)*3;
    my $ce = $cs + 2;
    for my $tr ($rs..$re) {
	for my $tc ($cs..$ce) {
	    my $ret = $sub->($grid->[$tr][$tc], $tr, $tc, $grid);
	    return $ret if $ret;
	}
    }
    return;
}

#
# Walk each row in the grid.
#
sub walk_rows {
    my ($grid, $sub) = @_;
    for my $r (0..8) {
	my $ret = $sub->($grid, $r);
	return $ret if $ret;
    }
    return;
}

#
# Same as above, but for columns.
#
sub walk_columns {
    my ($grid, $sub) = @_;
    for my $c (0..8) {
	my $ret = $sub->($grid, $c);
	return $ret if $ret;
    }
    return;
}

#
# Similar to above, but for the first field of each block.
#
sub walk_blocks {
    my ($grid, $sub) = @_;
    for my $r (0,3,6) {
	for my $c (0,3,6) {
	    my $ret = $sub->($grid, $r, $c);
	    return $ret if $ret;
	}
    }
    return;
}

#
# Convenience function, returns an array with randomized grid positions.  We can
# then walk the array to check all of the fields but in the randomized order.
#
sub randomize_grid_array {
    # Start by filling the fields in order.
    my @ar;
    my @rar;
    for my $r (0..8) {
	for my $c (0..8) {
	    push @ar, [$r, $c];
	}
    }

    # Now grab elements from the first array at random and populate a second
    # array with them.
    while (@ar) {
	push @rar, splice(@ar, rand(@ar), 1);
    }

    return \@rar;
}

#
# Sets a number bit in a single field.
#
sub set_field_bit {
    my ($field, $r, $c, $tr, $tc, $bit) = @_;
    return if $tr == $r && $tc == $c;
    $field->[1] |= $bit;
    return -1 if $field->[1] == 0x1ff;
    return;
}

#
# Sets a number bit for every field that can be affected by the target field.
#
sub set_bit {
    my ($grid, $r, $c, $num) = @_;
    $num ||= $grid->[$r][$c][0];
    return unless $num;

    my $bit = $numbit[$num];

    # Set the bit for every field in this block (local 3x3 grid)
    return -1 if
	walk_block($grid, $r, $c,
		   sub{set_field_bit($_[0],$r,$c,$_[1],$_[2],$bit)});

    # Set the bit for every field in this row
    return -1 if
	walk_row($grid, $r,
		 sub{set_field_bit($_[0],$r,$c,$_[1],$_[2],$bit)});

    # Set the bit for every field in this column
    return -1 if
	walk_column($grid, $c,
		    sub{set_field_bit($_[0],$r,$c,$_[1],$_[2],$bit)});
    return;
}

#
# Initial fill-in of bits.
#
sub fill_bits {
    my $grid = shift;

    my $ret = walk_grid($grid, sub{
	my ($field, $r, $c, $grid) = @_;
	return unless $field->[0];
	return set_bit($grid, $r, $c, $field->[0]);
			});
}

#
# Checks to see if a field can only be one num and sets and returns that num if
# so.  Returns -1 to indicate that the field cannot contain any number.
#
sub check_bits {
    my ($field, $r, $c, $grid) = @_;
    return if $field->[0];
    return -1 if $field->[1] == 0x1ff;
    for my $num (1..9) {
	if (($field->[1] ^ $numbit[$num]) == 0x1ff) {
	    $field->[0] = $num;
#	    print_grid($grid);
	    $found_field = 1;
	    return -1 if ckretnum(set_bit($grid, $r, $c, $num), -1);
	    return $num;
	}
    }
    return;
}

#
# Check a given row for any number that can only be in one field in that row.
#
sub check_row {
    my ($grid, $r) = @_;

    for my $num (1..9) {
	my $found;
	next if walk_row($grid, $r, sub {
	    my ($field, $r, $c, $grid) = @_;
	    return 1 if ($field->[0]||0) == $num;
	    return if $field->[1] & $numbit[$num];
	    return 1 if $found;
	    $found = [$field, $c];
			 });
	return -1 unless $found;

	# We now have exactly one field in this row that can be $num.
	$found->[0][0] = $num;
#	print_grid($grid);
	$found_field = 1;
	return -1 if set_bit($grid, $r, $found->[1], $num);
    }
    return;
}

#
# Check each row for any number that can only be in one field in a row.
#
sub check_rows {
    return walk_rows(shift(), \&check_row);
}

#
# Check a given column for any number that can only be in one field in that
# column.
#
sub check_column {
    my ($grid, $c) = @_;

    for my $num (1..9) {
	my $found;
	next if walk_column($grid, $c, sub {
	    my ($field, $r, $c, $grid) = @_;
	    return 1 if ($field->[0]||0) == $num;
	    return if $field->[1] & $numbit[$num];
	    return 1 if $found;
	    $found = [$field, $r];
			 });
	return -1 unless $found;

	# We now have exactly one field in this column that can be $num.
	$found->[0][0] = $num;
#	print_grid($grid);
	$found_field = 1;
	return -1 if set_bit($grid, $found->[1], $c, $num);
    }
    return;
}

#
# Check each column for any number that can only be in one field in a column.
#
sub check_columns {
    return walk_columns(shift(), \&check_column);
}

#
# Check a given block for any number that can only be in one field in that
# block.
#
sub check_block {
    my ($grid, $r, $c) = @_;

    for my $num (1..9) {
	my $found;
	next if walk_block($grid, $r, $c, sub {
	    my ($field, $r, $c, $grid) = @_;
	    return 1 if ($field->[0]||0) == $num;
	    return if $field->[1] & $numbit[$num];
	    return 1 if $found;
	    $found = [$field, $r, $c];
			 });
	return -1 unless $found;

	# We now have exactly one field in this block that can be $num.
	$found->[0][0] = $num;
#	print_grid($grid);
	$found_field = 1;
	return -1 if set_bit($grid, $found->[1], $c, $num);
    }
    return;
}

#
# Check each column for any number that can only be in one field in a column.
#
sub check_blocks {
    return walk_blocks(shift(), \&check_block);
}

#
# Checks to see if the grid is finished, or if every field is filled.
#
sub finished {!walk_grid(shift, sub {!shift->[0]})}

#
# Returns the number of bits set in a field.
#
sub bitcount {
    my $bits = shift;
    return 0 unless $bits;

    my $count = 0;
    for (1..9) {
	++$count if $bits & $numbit[$_];
    }
    return $count;
}

#
# Get a random number from those not set in a bits field.
#
sub randbit {
    my $bits = shift;
    my @nums;
    for (1..9) {
	push @nums, $_ if !($bits & $numbit[$_]);
    }
    return if !@nums;
    return $nums[rand @nums];
}

#
# Returns a random-ish field in the grid based on the fewest number of guesses
# possible for that field.
#
sub guess_field {
    my ($grid, $flags) = @_;
    return (int rand 9, int rand 9, 0) if $flags & $f{BLANK};

    my $maxcount = 0;
    my $fpos;

    # Get a random field order for guessing.
    my $rar = randomize_grid_array();

    # Find the first field with the most bits set (or fewest unset).
    for (@$rar) {
	my ($r, $c) = @$_;
	next if $grid->[$r][$c][0];

	my $count = bitcount($grid->[$r][$c][1]);

	# If we missed it, a bitcount of 9 indicates an invalid grid.
	return -1 if $count == 9;

	if ($count > $maxcount) {
	    $fpos = $_;
	    $maxcount = $count;

	    # We can stop here if we get a count >= 7
	    last if $count >= 7;
	}
    }
    return (@$fpos, $maxcount);
}

#
# Take an actual guess and call solve() on it to see if it pans out.
#
sub guess {
    my ($grid, $r, $c, $num) = @_;
    my $field = $grid->[$r][$c];

    # Apply the guess to the copy.
    $field->[0] = $num;
#    print_grid($grid);
    $found_field = 1;
    return -1 if ckretnum(set_bit($grid, $r, $c, $num), -1);
    # Continue to solve based on the guess.
    return solve($grid);
}

#
# Makes a copy and guesses until a solution is found or no numbers remain for
# the field.
#
sub multi_guess {
    my ($grid, $r, $c, $count) = @_;
    my $field = $grid->[$r][$c];
    return -1 if $field->[0] || $field->[1] == 0x1ff;

    while ($$count <= 8) {
	my $num = randbit($field->[1]);
	my $grid_copy = clone($grid);
	$grid_copy->[$r][$c][0] = $num;

	# These get set either way.
	$field->[1] |= $numbit[$num];
	++$$count;

	if (
	    !ckretnum(set_bit($grid_copy, $r, $c, $num), -1) &&
	    !ckretnum(guess($grid_copy, $r, $c, $num), -1)
	    ) {
	    # We've found a valid solution, return it.
	    return $grid_copy;
	}
    }

    # No solution found.
    return -1;
}

#
# Clears the bits in a grid.
#
sub clear_bits {walk_grid(shift(), sub{shift->[1]=0})}

#
# Solves the sudoku.  First arg is the grid and second is the flags (bitmap).
# Returns -1 if the grid is unsolveable, 1 for a single solution, 2 for more
# than one solution and undef to indicate that the grid has been solved but no
# additional solution has been attempted.
#
sub solve {
    my ($grid, $flags) = @_;
    $flags ||= 0;

    # Initial set of bits if we're just starting.
    if (!($flags&$f{BLANK}) && $flags&$f{START}) {
	return -1 if ckretnum(fill_bits($grid), -1);
    }

    # Just make sure we aren't starting on a finished grid and wasting our
    # time.
    return 1 if finished($grid);

    # Loop through these steps until we can no longer find any more fields, or
    # until all fields are filled in.
  CHECK: {
      # Skip if we're starting blank.
      last CHECK if $flags&$f{BLANK};

      # This is the global found which will be set if the number is found for
      # any new field.
      $found_field = 0;

      # Find any field that can only be one number.
      return -1 if ckretnum(walk_grid($grid, \&check_bits), -1);

      # Search for numbers that can only be in a single field in a given row,
      # column or block.
      return -1 if ckretnum(check_rows($grid), -1);
      return -1 if ckretnum(check_columns($grid), -1);
      return -1 if ckretnum(check_blocks($grid), -1);

      # Check if we're finished.  We can skip this if nothing was found.
      return 1 if $found_field && finished($grid);

      # If we've found anything we need to loop back through and check again,
      # unless the grid is finished..
      redo CHECK if $found_field;
    } #CHECK

    # Now we have to start guessing.
    my ($r, $c, $count) = guess_field($grid, $flags);
    return -1 if ckretnum($r, -1);

    my $retgrid = multi_guess($grid, $r, $c, \$count);
    return -1 if ckretnum($retgrid, -1);

    # If we're not checking for multiple solutions just update the grid and
    # return.
    if (!($flags & $f{CHECK})) {
	# Copy the grid back
	@$grid = @$retgrid;
	return 1;
    }

    # If we already found a grid then indicate that we found a second one and
    # return.
    if ($found_grid) {
	return 2;
    }

    # We need to check if there's a second solution.
    my $ret = multi_guess($grid, $r, $c, \$count);

    # Either way we copy the first completed grid over.
    @$grid = @$retgrid;

    # Indicate whether we found a second solution in the return value
    return ckretnum($ret, -1) ? 1 : 2;
}

#
# Prints a grid in plain text.
#
sub print_grid {
#    my (undef , undef, $line) = caller;
#    print "Line: $line\n";
#    return;
    my $grid = shift;
#    print "\e[H";
    print '/=====================================================\\',"\n";
    for my $r (0..8) {
	print 'H     |     |     H     |     |     H     |     |     H',"\n";
	print 'H';
	for my $c (0..8) {
	    print '  ',$grid->[$r][$c][0]||' ','  ';
	    if ($c % 3 == 2) {
		print 'H';
	    }
	    else {
		print '|';
	    }
	}
	print "\n";
	print 'H     |     |     H     |     |     H     |     |     H',"\n";
	if ($r == 8) {
	    print '\\=====================================================/',"\n";
	}
	elsif ($r % 3 == 2) {
	    print 'H=====================================================H',"\n";
	}
	else {
	    print 'H-----+-----+-----H-----+-----+-----H-----+-----+-----H',"\n";
	}
    }
}

#
# Reduce a full grid down to the minimum needed that still allows for a single
# solution.  Returns the new grid, or -1 to indicate an unsolved grid.  -2 will
# indicate some other problem (shouldn't happen).
#
sub reduce {
    # Make a copy of the grid to start with so we don't mess up the original
    # grid.
    my $grid = clone(shift);
    return -1 unless finished($grid);
    clear_bits($grid);

    # Remove random fields then check to see if the grid still has a single
    # solution.
    my $ar = randomize_grid_array();
    my $count = 81; # 9x9
    for (@$ar) {
	my ($r, $c) = @$_;
	my $grid_copy = clone($grid);
	$grid_copy->[$r][$c][0] = '';
	my $res = solve($grid_copy, $f{START}|$f{CHECK});
	return -2 if !$res || ckretnum($res, -1);
	next unless ckretnum($res, 1);

	$grid->[$r][$c][0] = '';
	return $grid if --$count <= $level;
    }

    return $grid;
}

#
# Adds a new puzzle grid to the pdf document.  If answer is set then it will
# print a small grid on one of the answer pages.
#
sub pdf_grid {
    my ($grid, $pdf, $answer) = @_;

    # Fix grid data
    $grid = clone($grid);
    for (@$grid) {
	for (@$_) {
	    $_ = $_->[0];
	}
    }

    my $pages = $pdf->pages;
    my $anum=int(($pages-1)/13)+((($pages-1)%13)&&1);
    my $pnum=$pages-$anum;
    $pnum = 0 if $pnum < 0;

    # Insert or fetch the correct page from the document.
    my $page;
    if (!$answer) {
	$page = $pdf->page($pnum+1);
	$page->mediabox($page_size);
	++$pnum;
    }
    elsif ($pnum % 12 == 1) {
	$page = $pdf->page();
	$page->mediabox($page_size);
    }
    else {
	$page = $pdf->openpage(0);
    }

    my $table = PDF::Table->new();

    my @page_dim = $page->get_mediabox;
    my $page_width = $page_dim[2]-$page_dim[0];
    my $page_height = $page_dim[3]-$page_dim[1];
    my $sec_width = $page_width;
    my $sec_height = $page_height;
    my $sec_x = 0;
    my $sec_y = 0;
    my $pos = 0;
    my $pos_x = 0;
    my $pos_y = 0;
    my $thick = 3;
    my $thin = 1;
    if ($answer) {
	$sec_width = int($sec_width/3);
	$sec_height = int($sec_height/4);
	$pos = ($pnum-1) % 12;
	$pos_x = $pos%3;
	$pos_y = int($pos/3);
	$sec_x = $sec_width * $pos_x;
	$sec_y = $sec_height * $pos_y;
	$thick = 2;
    }
    my $x_unit = int($sec_width/8.25);
    my $left = $answer ?
	$sec_x + int($x_unit*(3-$pos_x)/2) :
	$sec_x + int($x_unit/2);
    my $width = $answer ?
	$sec_width-$x_unit*2 :
	$sec_width-$x_unit;
    my $height = $width;
    my $row_height = int($height/9);
    $row_height -= 2 if $answer;
    my $top = $sec_y + $row_height * 2;
    my $start_y = $page_height - $top;
    my $font_size = int($row_height*0.7);
    my $header_x = int($left+$width/2);
    my $header_y = int($start_y+$row_height/2);
    my $header_size = $font_size;

    my $font = $pdf->corefont("Times", -encoding => "latin1");
    my $text = $page->text();
    $text->font($font, $header_size);
    $text->translate($header_x, $header_y);
    $text->text_center("Puzzle #$pnum " . uc $difficulty);

    my @row_props = map {{h_rule_w=>$_%3?$thin:$thick}} 1..9;
    my @col_props = map{{v_rule_w=>$_%3?$thin:$thick}} 0..8;

    # build the table layout
    # note: ignoring return values array
    $table->table(
	$pdf,
	$page,
	$grid,
	x => $left,
	y => $start_y,
	w => $width,
	h => $height,
	min_rh => $row_height,
	font_size => $font_size,
	justify => 'center',
	border_w => $thick,
	row_props => \@row_props,
	column_props => \@col_props,
	default_text => '',
	);
}

# Start with a blank grid.  Note that each grid position has two elements, the
# first one is the actual number in that grid location or the empty string.  The
# second grid is a bitmap containing a 9 bit number.  The 9 bits correspond to
# each number that might go in that location and a set bit represents the number
# being eliminated as a possibility.
for (1..$puzzles) {
    print "Generating puzzle #$_ of $puzzles\r";
    my @a_grid;
    @a_grid[0..8] = map {[map {['', 0]} 0..8]} 0..8;
    solve(\@a_grid, $f{BLANK});
    my $p_grid = reduce(\@a_grid, $level);
    pdf_grid($p_grid, $pdf);
    pdf_grid(\@a_grid, $pdf, 1);
}
print "\n";

# Save the pdf.
$pdf->saveas($filename);
