#!usr/bin/perl -w
############################################################################
# Module:      DIGS.pm   database-integrated genome screening (DIGS)
# Description: Functions for implementing DIGS
# History:     December  2013: Created by Robert Gifford 
############################################################################
package DIGS;

############################################################################
# Import statements/packages (externally developed packages)
############################################################################
use strict;

############################################################################
# Import statements/packages (internally developed packages)
############################################################################

# Base classes
use Base::FileIO;
use Base::Console;
use Base::DevTools;

# Program components
use DIGS::Initialise;    # Initialises the DIGS tool
use DIGS::ScreenBuilder; # To set up a DIGS run
use DIGS::Defragment;    # Cluster/defragment/consolidate tools

############################################################################
# Globals
############################################################################

# Base objects
my $fileio    = FileIO->new();
my $console   = Console->new();
my $devtools  = DevTools->new();
1;

############################################################################
# LIFECYCLE
############################################################################

#***************************************************************************
# Subroutine:  new
# Description: create new DIGS 'object'
#***************************************************************************
sub new {

	my ($invocant, $parameter_ref) = @_;
	my $class = ref($invocant) || $invocant;

	# Declare empty data structures
	my %crossmatching;

	# Set member variables
	my $self = {
		
		# Global settings
		process_id             => $parameter_ref->{process_id},
		program_version        => $parameter_ref->{program_version},
		
		# Flags
		verbose                => $parameter_ref->{verbose},
		force                  => $parameter_ref->{force},
		
		# Member classes 
		blast_obj              => $parameter_ref->{blast_obj},

		# MySQL database connection parameters
		mysql_username         => $parameter_ref->{mysql_username}, 
		mysql_password         => $parameter_ref->{mysql_password},
		db_name                => '',   # Obtained from control file or user
		mysql_server           => '',   # Obtained from control file or user

		# Parameters for DIGS
		query_na_fasta         => '',   # Obtained from control file
		query_aa_fasta         => '',   # Obtained from control file
		aa_reference_library   => '',   # Obtained from control file
		na_reference_library   => '',   # Obtained from control file
		bitscore_min_tblastn   => '',   # Obtained from control file
		bitscore_min_blastn    => '',   # Obtained from control file
		seq_length_minimum     => '',   # Obtained from control file

		# Paths used in DIGS process
		genome_use_path        => $parameter_ref->{genome_use_path},
		output_path            => $parameter_ref->{output_path},
		reference_na_fasta     => '',   
		reference_aa_fasta     => '',   
		blast_threads          => '',   # Obtained from control file

		# Data structures
		crossmatching          => \%crossmatching,

	};
	
	bless ($self, $class);
	return $self;
}

############################################################################
# MAIN LOOP
############################################################################

##***************************************************************************
# Subroutine:  run_digs_process
# Description: handler for main DIGS functions 
#***************************************************************************
sub run_digs_process {

	my ($self, $ctl_file, $option) = @_;

	$self->show_title();  

	# Initialise
	my $valid = undef;
	if ($ctl_file) {	
		$valid = $self->initialise($option, $ctl_file);
	}
	elsif ($option > 1 and $option <= 5) {
		# Show error
		print "\n\t  Option '-m=$option' requires an infile\n\n";	
		exit;
	}
	# Hand off to DIGS functions
	elsif ($option eq 1) { 
		
		# Check the target sequences are formatted for BLAST
		$self->prepare_target_files_for_blast();
	}
	else {				
		# Show error
		print "\n\t  Unrecognized option '-m=$option'\n\n";
		exit;
	}


	if ($valid) {
	
		if ($option eq 2) { 
	
			# Run a DIGS process
			$self->perform_digs();	
		}
		elsif ($option eq 3) { 
	
			# Reassign data in digs_results table
			$self->reassign();	
		}
		elsif ($option eq 4) {
		
			# Interactively defragment results 	
			$self->interactive_defragment();	
		}
		elsif ($option eq 5) { 
	
			# Combine digs_results into higher order locus structures
			$self->consolidate_loci();
		}
	}

	# Show final summary and exit message
	$self->wrap_up($option);

}

############################################################################
# PRIMARY FUNCTIONS (TOP LEVEL)
############################################################################

#***************************************************************************
# Subroutine:  prepare_target_files_for_blast
# Description: create index files for all target databases
#***************************************************************************
sub prepare_target_files_for_blast {

	my ($self) = @_;

	# Format targets files for BLAST searching
	my $target_db_obj = TargetDB->new($self);
	$target_db_obj->format_targets_for_blast();

}

#***************************************************************************
# Subroutine:  perform_digs
# Description: do the core database-integrated genome screening processes
#***************************************************************************
sub perform_digs {

	my ($self, $mode) = @_;

	# Get handle for the 'searches_performed' table, updated in this loop
	my $db_ref         = $self->{db};
	my $searches_table = $db_ref->{searches_table};
	my $defragment_obj = Defragment->new($self);

	# Iterate through the list of DIGS queries, dealing each in turn 
	# Each DIGS query constitutes a probe sequence and a target FASTA file
	my $queries_completed = 0;
	my $queries_ref = $self->{queries};
	unless ($queries_ref) { die; }   # Sanity checking
	my @probes = keys %$queries_ref; # Get the list of queries
	print "\n\t ### Starting database-integrated genome screening";
	foreach my $probe_name (@probes) {
		
		# Get the array of queries for this target file
		my $probe_queries = $queries_ref->{$probe_name};
		foreach my $query_ref (@$probe_queries) {  
	
			# Increment query count
			$queries_completed++;		
			$self->{queries_completed} = $queries_completed;

			# Do the 1st BLAST (probe vs target)
			$self->search_target_file_using_blast($query_ref);
		
			# For this target, create a non-redundant locus set
			my @new_hits;
			$defragment_obj->compile_nonredundant_locus_set($query_ref, \@new_hits);
			
			# Extract newly identified or extended sequences
			my @extracted;
			my $target_path = $query_ref->{target_path};
			$self->extract_sequences_from_target_file($target_path, \@new_hits, \@extracted);	
			
			# Do the 2nd BLAST (hits from 1st BLAST vs reference library)
			$self->classify_sequences_using_blast(\@extracted, $query_ref);
			
			# Update tables in the screening database to reflect new information
			$self->update_db(\@extracted, 'digs_results_table', 1);
	
			# Update the searches_performed table, indicating search has completed
			$searches_table->insert_row($query_ref);
		
			# Show a status update in the console
			$self->show_digs_progress();			
		}	
	}
}

#***************************************************************************
# Subroutine:  reclassify_digs_results_table_seqs
# Description: classify sequences already in the digs_results_table 
#***************************************************************************
sub reclassify_digs_results_table_seqs {
	
	my ($self) = @_;

	# Get data structures, paths and flags from self
	my $blast_obj   = $self->{blast_obj};
	my $result_path = $self->{report_dir};
	my $verbose     = $self->{verbose};

	# Get the connection to the digs_results table (so we can update it)
	my $db          = $self->{db};
	my $digs_results_table = $db->{digs_results_table};
	unless ($digs_results_table) { die; }
	
	# Get the sequences to reassign 
	my $reassign_loci = $self->{reassign_loci};
	unless ($reassign_loci) { die; }
	my $num_to_reassign = scalar @$reassign_loci;
	print "\n\n\t  Reassigning $num_to_reassign hits in the digs_results table\n";

	# Iterate through the loci, doing the reassign process for each
	my $count = 0;
	foreach my $locus_ref (@$reassign_loci) {
		
		# Set the linking to the BLAST result table
		my $record_id       = $locus_ref->{record_id};	
		my $extract_start   = $locus_ref->{extract_start};
		my $extract_end     = $locus_ref->{extract_end};
		$locus_ref->{subject_start} = $extract_start;
		$locus_ref->{subject_end}   = $extract_end;
		delete $locus_ref->{extract_start};
		delete $locus_ref->{extract_end};
	
		# Execute the 'reverse' BLAST (2nd BLAST in a round of paired BLAST)	
		my $previous_assign = $locus_ref->{assigned_name};
		my $previous_gene   = $locus_ref->{assigned_gene};
		$self->classify_sequence_using_blast($locus_ref);
		
		$count++;
		if (($count % 100) eq 0) { print "\n\t  Checked $count rows"; }

		my $assigned_name = $locus_ref->{assigned_name};
		my $assigned_gene = $locus_ref->{assigned_gene};
		if ($assigned_name ne $previous_assign or  $assigned_gene ne $previous_gene) {
				
			if ($verbose) {  # Report the outcome
				print "\n\t\t      - reassigned: was previously '$previous_assign ($previous_gene)'";
			}
			
			# Update the matrix
			my $previous_key = $previous_assign . '_' . $previous_gene;
			my $assigned_key = $assigned_name . '_' . $assigned_gene;	
			$self->update_cross_matching($previous_key, $assigned_key);
				
			# Insert the data
			my $where = " WHERE record_id = $record_id ";
			delete $locus_ref->{record_id}; # Required to remove this
			delete $locus_ref->{organism};  # Update not required for this field
			$digs_results_table->update($locus_ref, $where);
		}
	}
	
	# Write out the cross-matching matrix
	$self->show_cross_matching();

	# Cleanup
	my $output_dir = $self->{report_dir};
	my $command1 = "rm -rf $output_dir";
	system $command1;
}


############################################################################
# INTERNAL FUNCTIONS: MAIN DIGS LOOP
############################################################################

#***************************************************************************
# Subroutine:  search_target_file_using_blast
# Description: execute a similarity search and parse the results
#***************************************************************************
sub search_target_file_using_blast {
	
	my ($self, $query_ref) = @_;

	# Get relevant member variables and objects
	my $blast_obj    = $self->{blast_obj};
	my $tmp_path     = $self->{tmp_path};
	my $min_length   = $self->{seq_length_minimum};
	my $min_score    = $self->{bitscore_minimum};

	# Sanity checking
	unless ($min_length) { die; }
	unless ($min_score)  { die; }	
	unless ($blast_obj)  { die; } 
	unless ($tmp_path)   { $devtools->print_hash($self); die; } 

	# Get query details
	my $probe_id        = $query_ref->{probe_id};
	my $blast_alg       = $query_ref->{blast_alg};
	my $probe_name      = $query_ref->{probe_name};
	my $probe_gene      = $query_ref->{probe_gene};
	my $probe_type      = $query_ref->{probe_type};
	my $probe_path      = $query_ref->{probe_path};
	my $organism        = $query_ref->{organism};
	my $version         = $query_ref->{target_version};
	my $datatype        = $query_ref->{target_datatype};
	my $target_name     = $query_ref->{target_name};
	my $target_path     = $query_ref->{target_path};
	my $result_file     = $tmp_path . "/$probe_id" . "_$target_name.blast_result.tmp";
	unless ($probe_id and $blast_alg) { die; }

	# Do BLAST similarity search
	my $completed = $self->{queries_completed};	
	print "\n\n\t  $blast_alg: $completed: '$organism' ($version, $datatype)";
	print   "\n\t  target: '$target_name'";
	print   "\n\t  probe:  '$probe_id'";   
	$blast_obj->blast($blast_alg, $target_path, $probe_path, $result_file);
	# TODO: catch error from BLAST and don't update "Searches_performed" table	
	
	# Extract the results from tabular format BLAST output
	my @hits;
	$blast_obj->parse_tab_format_results($result_file, \@hits);
	my $rm_command = "rm $result_file";
	system $rm_command; # Remove the result file

	# Summarise raw results of BLAST search
	my $num_hits = scalar @hits;
	if ($num_hits > 0) {
		print "\n\t\t # $num_hits matches to probe: $probe_name, $probe_gene";
	}
	
	# Apply filters & store results
	my $num_retained_hits = 0;
	my $score_exclude_count = '0';
	my $length_exclude_count = '0';
	foreach my $hit_ref (@hits) {

		my $skip = undef;
		# Apply length cutoff
		if ($min_length) { # Skip sequences that are too short
			my $start  = $hit_ref->{aln_start};
			my $end    = $hit_ref->{aln_stop};
			if ($end - $start < $min_length) {  
				$skip = 'true';
				$length_exclude_count++; 				
			}
		}
		# Apply bitscore cutoff
		if ($min_score) { 
			# Skip sequences that have too low bit scores
			my $query_score = $hit_ref->{bitscore};
			if ($query_score < $min_score) { 
				unless ($skip) { # Don't count as a bit_score exclusion if already exclude via length
					$skip = 'true';
					$score_exclude_count++;
				}
			}
		}	
		unless ($skip) {		
			# Insert values into 'active_set' table
			$self->insert_row_in_active_set_table($query_ref, $hit_ref);
			$num_retained_hits++;			
		}
	} 

	# Show summary of BLAST results after filtering
	if ($score_exclude_count or $length_exclude_count) {
		print "\n\t\t # $num_retained_hits matches above threshold ";
		print "(excluded: $length_exclude_count < length; $score_exclude_count < bitscore)";
	}
	
	return $num_hits;
}

#***************************************************************************
# Subroutine:  insert_row_in_active_set_table
# Description: insert a BLAST result as a row into the active set table
#***************************************************************************
sub insert_row_in_active_set_table {

	my ($self, $query_ref, $hit_ref) = @_;

	# Get screening database table objects
	my $db_ref           = $self->{db};
	my $active_set_table = $db_ref->{active_set_table};
	unless ($db_ref)          { die; } 

	my $probe_id        = $query_ref->{probe_id};
	my $probe_name      = $query_ref->{probe_name};
	my $probe_gene      = $query_ref->{probe_gene};
	my $probe_type      = $query_ref->{probe_type};
	my $probe_path      = $query_ref->{probe_path};
	my $organism        = $query_ref->{organism};
	my $version         = $query_ref->{target_version};
	my $datatype        = $query_ref->{target_datatype};
	my $target_name     = $query_ref->{target_name};
	my $target_path     = $query_ref->{target_path};

	$hit_ref->{digs_result_id}  = 0;
	$hit_ref->{organism}        = $organism;
	$hit_ref->{target_version}  = $version;
	$hit_ref->{target_datatype} = $datatype;
	$hit_ref->{target_name}     = $target_name;
	$hit_ref->{probe_id}        = $probe_id;
	$hit_ref->{probe_name}      = $probe_name;
	$hit_ref->{probe_gene}      = $probe_gene;
	$hit_ref->{probe_type}      = $probe_type;
	$hit_ref->{subject_start}   = $hit_ref->{aln_start};  # Rename to match DB
	$hit_ref->{subject_end}     = $hit_ref->{aln_stop};   # Rename to match DB
	$hit_ref->{query_end}       = $hit_ref->{query_stop}; # Rename to match DB
	$active_set_table->insert_row($hit_ref);

}

#***************************************************************************
# Subroutine:  extract_sequences_from_target_file
# Description: extract sequences from target databases
#***************************************************************************
sub extract_sequences_from_target_file {

	my ($self, $target_path, $loci_ref, $extracted_ref) = @_;

	# Get paths, objects, data structures and variables from self
	my $blast_obj = $self->{blast_obj};
	my $verbose   = $self->{verbose};
	my $buffer    = $self->{extract_buffer};

	# Iterate through the list of sequences to extract
	my $new_loci = 0;
	foreach my $locus_ref (@$loci_ref) {
			
		# Add any buffer 
		if ($buffer) { 
			my $orientation = $locus_ref->{orientation};
			$self->add_buffer_to_sequence($locus_ref, $orientation); 
		}
	
		# Extract the sequence
		my $sequence   = $blast_obj->extract_sequence($target_path, $locus_ref);
		if ($sequence) {
			
			# If we extracted a sequence, update the data for this locus
			my $seq_length = length $sequence; # Set sequence length
			if ($verbose) { print "\n\t\t    - Extracted sequence: $seq_length nucleotides "; }
			$locus_ref->{extract_start}   = $locus_ref->{start};
			$locus_ref->{extract_end}     = $locus_ref->{end};
			$locus_ref->{sequence}        = $sequence;
			$locus_ref->{sequence_length} = $seq_length;
			push (@$extracted_ref, $locus_ref);
			$new_loci++;
		}
		elsif ($verbose) { 
			print "\n\t\t    # Sequence extraction failed ";
		}
	}	
	return $new_loci;
}

#***************************************************************************
# Subroutine:  add_buffer_to_sequence
# Description: eadd leading-and-trailing buffer to extract coordinates
#***************************************************************************
sub add_buffer_to_sequence {

	my ($self, $hit_ref, $orientation) = @_;

	my $buffer = $self->{extract_buffer};
		
	if ($orientation eq '-') {
		$hit_ref->{start} = $hit_ref->{start} + $buffer;
		$hit_ref->{end}   = $hit_ref->{end} - $buffer;
		if ($hit_ref->{end} < 1) { # Don't allow negative coordinates
			$hit_ref->{end} = 1;
		}	
	}
	else {
		$hit_ref->{start} = $hit_ref->{start} - $buffer;
		if ($hit_ref->{start} < 1) { # Don't allow negative coordinates
			$hit_ref->{start} = 1;
		}	
		$hit_ref->{end}   = $hit_ref->{end} + $buffer;
	}
}

#***************************************************************************
# Subroutine:  classify_sequences_using_blast
# Description: classify a set of sequences using blast
#***************************************************************************
sub classify_sequences_using_blast {

	my ($self, $extracted_ref, $query_ref) = @_;

	my $verbose = $self->{verbose};
	my $assigned_count   = 0;
	my $crossmatch_count = 0;
	unless ($query_ref) { die; }
	foreach my $locus_ref (@$extracted_ref) { # Iterate through the matches

		# Execute the 'reverse' BLAST (2nd BLAST in a round of paired BLAST)
		my $blast_alg = $self->classify_sequence_using_blast($locus_ref);
		my $assigned  = $locus_ref->{assigned_name};
		unless ($assigned) { die; }
		if ($assigned) { $assigned_count++; }

		# Get the unique key for this probe
		my $probe_name  = $query_ref->{probe_name};
		my $probe_gene  = $query_ref->{probe_gene};
		my $probe_key   = $probe_name . '_' . $probe_gene; 		

		# Record cross-matching
		if ($probe_key ne $assigned) {
			$crossmatch_count++;
			$self->update_cross_matching($probe_key, $assigned);
		}
	}
	if ($assigned_count > 0) {
		print "\n\t\t # $assigned_count extracted sequences classified";
	}
	if ($verbose) {	
		print "\n\t\t # $crossmatch_count cross-matched to something other than the probe";
	}
}

#***************************************************************************
# Subroutine:  classify_sequence_using_blast
# Description: classify a nucleotide sequence using blast 
#***************************************************************************
sub classify_sequence_using_blast {

	my ($self, $locus_ref) = @_;

	# Get paths and objects from self
	my $result_path = $self->{tmp_path};
	my $blast_obj   = $self->{blast_obj};
	my $verbose     = $self->{verbose};
	unless ($blast_obj)   { die; } 
	unless ($result_path) { die; }
	
	# Get required data about the query sequence
	my $sequence   = $locus_ref->{sequence};
	my $probe_type = $locus_ref->{probe_type};
	unless ($probe_type) { die; } # Sanity checking
	unless ($sequence)   { die; } # Sanity checking

	# Make a FASTA query file
	$sequence =~ s/-//g;   # Remove any gaps that might happen to be there
	$sequence =~ s/~//g;   # Remove any gaps that might happen to be there
	$sequence =~ s/\s+//g; # Remove any gaps that might happen to be there
	my $fasta      = ">TEMPORARY\n$sequence";
	my $query_file = $result_path . '/TEMPORARY.fas';
	$fileio->write_text_to_file($query_file, $fasta);
	my $result_file = $result_path . '/TEMPORARY.blast_result';
	
	# Do the BLAST according to the type of sequence (AA or NA)
	my $blast_alg = $self->get_blast_algorithm($probe_type);
	my $lib_path  = $self->get_blast_library_path($probe_type);
	my $lib_file;
	if    ($probe_type eq 'ORF') {  $lib_file = $self->{aa_reference_library}; }
	elsif ($probe_type eq 'UTR') {  $lib_file = $self->{na_reference_library}; }
	else  { die; }
	unless ($lib_file)  { die; }

	# Execute the call to BLAST and parse the results
	$blast_obj->blast($blast_alg, $lib_path, $query_file, $result_file);
	my @results;
	$blast_obj->parse_tab_format_results($result_file, \@results);

	# Define some variables for capturing the result
	my $top_match = shift @results;
	my $query_start   = $top_match->{query_start};
	my $query_end     = $top_match->{query_stop};
	my $subject_start = $top_match->{aln_start};
	my $subject_end   = $top_match->{aln_stop};
	my $assigned_key  = $top_match->{scaffold};	
	my $assigned;

	# Deal with a query that matched nothing in the 2nd BLAST search
	unless ($assigned_key) {
		$self->set_default_values_for_unassigned_locus($locus_ref);	
		$assigned = undef;
	}
	else {	# Assign the extracted sequence based on matches from 2nd BLAST search

		# Split assigned to into (i) refseq match (ii) refseq description (e.g. gene)	
		my @assigned_key  = split('_', $assigned_key);
		my $assigned_gene = pop @assigned_key;
		my $assigned_name = shift @assigned_key;
		#$assigned_name = join ('_', @assigned_name);
		$locus_ref->{assigned_name}  = $assigned_name;
		$locus_ref->{assigned_gene}  = $assigned_gene;
		$locus_ref->{identity}       = $top_match->{identity};
		$locus_ref->{bitscore}       = $top_match->{bitscore};
		$locus_ref->{evalue_exp}     = $top_match->{evalue_exp};
		$locus_ref->{evalue_num}     = $top_match->{evalue_num};
		$locus_ref->{mismatches}     = $top_match->{mismatches};
		$locus_ref->{align_len}      = $top_match->{align_len};
		$locus_ref->{gap_openings}   = $top_match->{gap_openings};
		$locus_ref->{query_end}      = $query_end;
		$locus_ref->{query_start}    = $query_start;
		$locus_ref->{subject_end}    = $subject_end;
		$locus_ref->{subject_start}  = $subject_start;
		if ($verbose) { 
			my $id = $locus_ref->{record_id};
			print "\n\t\t    - Record '$id' assigned as '$assigned_name ($assigned_gene)'";
		 	print " via $blast_alg comparison to $lib_file";
		 }
		$assigned = $assigned_name . '_' . $assigned_gene;
	}

	# Clean up
	my $command1 = "rm $query_file";
	my $command2 = "rm $result_file";
	system $command1;
	system $command2;
	
	return $blast_alg;
}

#***************************************************************************
# Subroutine:  set_default_values_for_unassigned_locus
# Description: set default values for an unassigned extracted sequence
#***************************************************************************
sub set_default_values_for_unassigned_locus {

	my ($self, $hit_ref) = @_;

	$hit_ref->{assigned_name}    = 'Unassigned';
	$hit_ref->{assigned_gene}    = 'Unassigned';
	$hit_ref->{identity}         = 0;
	$hit_ref->{bitscore}         = 0;
	$hit_ref->{evalue_exp}       = 0;
	$hit_ref->{evalue_num}       = 0;
	$hit_ref->{mismatches}       = 0;
	$hit_ref->{align_len}        = 0;
	$hit_ref->{gap_openings}     = 0;
	$hit_ref->{query_end}        = 0;
	$hit_ref->{query_start}      = 0;
	$hit_ref->{subject_end}      = 0;
	$hit_ref->{subject_start}    = 0;
	
}

#***************************************************************************
# Subroutine:  get_blast_algorithm
# Description: determine which blast algorithm to use based on settings
#***************************************************************************
sub get_blast_algorithm {

	my ($self, $probe_type) = @_;
	
	my $blast_alg;
	if    ($probe_type eq 'UTR') { $blast_alg = 'blastn'; }
	elsif ($probe_type eq 'ORF') { $blast_alg = 'blastx'; }
	else { die "\n\t Unknown probe type '$probe_type '\n\n"; }
	
	return $blast_alg;
}

#***************************************************************************
# Subroutine:  get_blast_library_path
# Description: get path to a reference library, based on settings
#***************************************************************************
sub get_blast_library_path {

	my ($self, $probe_type) = @_;
	my $lib_path;
	
	if ($probe_type eq 'UTR') { 
		$lib_path = $self->{blast_utr_lib_path};
		unless ($lib_path) {
			$devtools->print_hash($self); 
			die "\n\t NO UTR LIBRARY defined";
		}
	}
	elsif ($probe_type eq 'ORF') { 
		$lib_path = $self->{blast_orf_lib_path};
		unless ($lib_path) {
			die "\n\t NO ORF LIBRARY defined";
		}
	}	
	return $lib_path;
}

#***************************************************************************
# Subroutine:  update_db
# Description: update the screening DB based on a completed round of DIGS
#***************************************************************************
sub update_db {

	my ($self, $extracted_ref, $table_name, $update) = @_;
		
	# Get parameters from self
	my $db_ref              = $self->{db};
	my $verbose             = $self->{verbose};
	my $digs_results_table  = $db_ref->{$table_name}; 
	my $active_set_table    = $db_ref->{active_set_table}; 
	my $blast_chains_table  = $db_ref->{blast_chains_table}; 

	# Iterate through the extracted sequences
	my $deleted = '0';
	foreach my $hit_ref (@$extracted_ref) {
		
		# Insert the data to the digs_results table
		my $digs_result_id;
		if ($update) {
			$digs_result_id = $digs_results_table->insert_row($hit_ref);
		}
		else {
			$digs_result_id = $hit_ref->{digs_result_id};
			my $where = " WHERE record_id = $digs_result_id ";
			my %update;
			$update{extract_start} = $hit_ref->{extract_start};
			$update{extract_end}   = $hit_ref->{extract_end};
			$digs_results_table->update(\%update, $where);		
		}
		
		# Insert the data to the BLAST_chains table
		my $blast_chains = $hit_ref->{blast_chains};
		if ($blast_chains) {		
			my @blast_ids = keys %$blast_chains;
			foreach my $blast_id (@blast_ids) {							
				my $data_ref = $blast_chains->{$blast_id};
				$data_ref->{digs_result_id} = $digs_result_id;	
				$blast_chains_table->insert_row($data_ref);
			}
		}
		unless ($digs_result_id) { die; }
		
		# Delete superfluous data from the digs_results table
		my $digs_result_ids_ref = $hit_ref->{digs_result_ids};
		foreach my $old_digs_result_id (@$digs_result_ids_ref) {			
			
			# Where we updated an existing record, keep that record
			unless ($old_digs_result_id eq $digs_result_id) {

				# Delete superfluous extract rows
				my $extracted_where = " WHERE record_id = $old_digs_result_id ";	
				if ($verbose) { print "\n\t\t    - Deleting redundant locus '$old_digs_result_id'"; }
				$digs_results_table->delete_rows($extracted_where);
				$deleted++;

				# Update extract IDs			
				my $chains_where = " WHERE record_id = $old_digs_result_id ";
				my %new_id;
				$new_id{digs_result_id} = $digs_result_id;	
				$blast_chains_table->update(\%new_id, $chains_where);
			}
		}
	}

	# Flush the active set table
	$active_set_table->flush();

	# Return the number
	return $deleted;
}

#***************************************************************************
# Subroutine:  show_digs_progress
# Description: show progress in DIGS screening
#***************************************************************************
sub show_digs_progress {

	my ($self) = @_;

	# Get the counts
	my $total_queries   = $self->{total_queries};
	my $completed       = $self->{queries_completed};	
	unless ($completed and $total_queries) { die; } # Sanity checking
	
	# Calculate percentage progress
	my $percent_prog    = ($completed / $total_queries) * 100;
	my $f_percent_prog  = sprintf("%.2f", $percent_prog);
	#print "\n\t\t  ";
	print "\n\t\t # done $completed of $total_queries queries (%$f_percent_prog)";
}

#***************************************************************************
# Subroutine:  wrap_up
# Description: clean-up functions etc prior to exiting program
#***************************************************************************
sub wrap_up {

	my ($self, $option) = @_;

	# Remove the output directory
	my $output_dir = $self->{report_dir};
	if ($output_dir) {
		my $command1 = "rm -rf $output_dir";
		system $command1;
	}
	
	# Show cross matching at end if verbose output setting is on
	my $verbose = $self->{verbose};
	if ($verbose and $option eq 2 and $option eq 3) { 
		$self->show_cross_matching();
	}

	# Print finished message
	print "\n\n\t ### Process completed ~ + ~ + ~";

}

############################################################################
# INTERNAL FUNCTIONS: recording cross-matching
###########################################################################

#***************************************************************************
# Subroutine:  update_cross_matching
# Description: update a hash to record cross-matches
#***************************************************************************
sub update_cross_matching {

	my ($self, $probe_key, $assigned) = @_;
	
	my $crossmatch_ref = $self->{crossmatching};
	
	if ($crossmatch_ref->{$probe_key}) {
		my $cross_matches_ref = $crossmatch_ref->{$probe_key};
		if ($cross_matches_ref->{$assigned}) {
			$cross_matches_ref->{$assigned}++;
		}
		else {
			$cross_matches_ref->{$assigned} = 1;
		}
	}
	else {
		my %crossmatch;
		$crossmatch{$assigned} = 1;
		$crossmatch_ref->{$probe_key} = \%crossmatch;
	}
}

#***************************************************************************
# Subroutine:  show_cross_matching
# Description: show contents of hash that records cross-matches
#***************************************************************************
sub show_cross_matching {

	my ($self) = @_;

	print "\n\n\t  Summary of cross-matching";   
	my $crossmatch_ref = $self->{crossmatching};
	my @probe_names = keys 	%$crossmatch_ref;
	foreach my $probe_name (@probe_names) {
		
		my $cross_matches_ref = $crossmatch_ref->{$probe_name};
		my @cross_matches = keys %$cross_matches_ref;
		foreach my $cross_match (@cross_matches) {
			my $count = $cross_matches_ref->{$cross_match};
			print "\n\t\t #   $count x $probe_name to $cross_match";
		}
	}
}

############################################################################
# INTERNAL FUNCTIONS: interacting with screening DB (indexing, sorting)
############################################################################

############################################################################
# INTERNAL FUNCTIONS: title and help display
############################################################################

#***************************************************************************
# Subroutine:  show_title
# Description: show command line title blurb 
#***************************************************************************
sub show_title {

	my ($self) = @_;

	my $version_num =  $self->{program_version};
	unless ($version_num) {
		$version_num = 'version undefined (use with caution)';
	}
	$console->refresh();
	my $title       = "DIGS (version: $version_num)";
	my $description = 'Database-Integrated Genome Screening';
	my $author      = 'Robert J. Gifford';
	my $contact	    = '<robert.gifford@glasgow.ac.uk>';
	$console->show_about_box($title, $version_num, $description, $author, $contact);
}

#***************************************************************************
# Subroutine:  show_help_page
# Description: show help page information
#***************************************************************************
sub show_help_page {

	my ($self) = @_;

	# Create help menu
	$console->refresh();
	my $program_version = $self->{program_version};
	
    my $HELP   = "\n\n\t ### DIGS version $program_version";
       $HELP .= "\n\t ### usage: $0 m=[option] -i=[control file] -h=[help]\n";

       $HELP  .= "\n\t ### Main functions\n"; 
	   $HELP  .= "\n\t -m=1  Prepare target files (index files for BLAST)";		
	   $HELP  .= "\n\t -m=2  Do DIGS"; 
	   $HELP  .= "\n\t -m=3  Reassign loci"; 
	   $HELP  .= "\n\t -m=4  Defragment loci"; 
	   $HELP  .= "\n\t -m=5  Consolidate loci\n"; 
	   $HELP  .= "\n\t Target path variable (\$DIGS_GENOMES) is set to '$ENV{DIGS_GENOMES}'";

	   $HELP  .= "\n\n\t Run  $0 -e to see information on utility functions\n\n\n"; 

	print $HELP;
}

############################################################################
# Development
############################################################################

#***************************************************************************
# Subroutine:  prepare_locus_update 
# Description: 
#***************************************************************************
sub prepare_locus_update {

	my ($self, $loci_ref) = @_;

	# Get parameters from self
	foreach my $hit_ref (@$loci_ref) {
	
		$hit_ref->{extract_start}   = $hit_ref->{start};
		$hit_ref->{extract_end}     = $hit_ref->{end};
		$hit_ref->{sequence}        = 'NULL';
		$hit_ref->{sequence_length} = 0;
		#$devtools->print_hash($hit_ref); die;
	}
}

############################################################################
# EOF
############################################################################
