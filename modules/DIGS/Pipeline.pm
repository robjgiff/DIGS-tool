#!/usr/bin/perl -w
############################################################################
# Module:      Pipeline.pm
# Description: Genome screening pipeline using reciprocal BLAST
# History:     December 2009: Created by Robert Gifford 
############################################################################
package Pipeline;

############################################################################
# Import statements/packages (externally developed packages)
############################################################################
use strict;

############################################################################
# Import statements/packages (internally developed packages)
############################################################################

# Base classes
use Base::FileIO;
use Base::DevTools;
use Base::Console;
use Base::Sequence;    # For performing basic sequence manipulations

# Program components
use DIGS::ScreenBuild; # Functions to set up screen

############################################################################
# Globals
############################################################################

# Default minimum length of BLAST hit to extract 
my $default_min_seqlen = 100; # minimum sequence length of BLAST hit to extract
my $process_dir_warn   = 100; # folders in process directory to trigger warning 

# Base objects
my $fileio    = FileIO->new();
my $devtools  = DevTools->new();
my $console   = Console->new();
my $verbose   = undef;
1;

############################################################################
# LIFECYCLE
############################################################################

#***************************************************************************
# Subroutine:  new
# Description: create new Pipeline 'object'
#***************************************************************************
sub new {

	my ($invocant, $parameter_ref) = @_;
	my $class = ref($invocant) || $invocant;

	# Set member variables
	my $self = {
		
		# Flags
		process_id             => $parameter_ref->{process_id},
		
		# Paths and member variables
		blast_bin_path         => $parameter_ref->{blast_bin_path},
		genome_use_path        => $parameter_ref->{genome_use_path},
		output_path            => $parameter_ref->{output_path},

		# Database variables
		db_name                => '',   # Obtained from control file
		server                 => '',   # Obtained from control file
		username               => '',   # Obtained from control file
		password               => '',   # Obtained from control file
	
		# Member classes 
		blast_obj              => $parameter_ref->{blast_obj},
	};
	
	bless ($self, $class);
	return $self;
}

############################################################################
# SECTION: Handler functions 
############################################################################

#***************************************************************************
# Subroutine:  run_digs_function
# Description: handler for various utility processes 
#***************************************************************************
sub run_digs_function {

	my ($self, $option, $ctl_file) = @_;

	# summarising genomes does not require a file path
	if ($option eq 8) {  
		my $genome_obj = TargetDB->new($self);
		$genome_obj->summarise_genomes();    
		return;
	}

	# Try opening control file first
	my @ctl_file;
	my $valid = $fileio->read_file($ctl_file, \@ctl_file);
	unless ($valid) {
		print "\n\t ### Couldn't open control file '$ctl_file'\n\n\n ";
		exit;
	}	
	# Create a screening DB 
	if ($option eq 1)    {
		$self->create_screening_db($ctl_file);
		return;
	}

	# For the following functions, nitialise the DIGS tool using the control file
	$self->initialise($ctl_file);
	my $db = $self->{db};
	
	# Hand off to functions 2-7, based on the options received
	if ($option eq 2)    {  
		$self->screen();	
	}
	elsif ($option eq 3) { # DB summary
		$db->summarise_db();
	}
	elsif ($option eq 4) { # Retrieve data
		$self->retrieve();
	}
	elsif ($option eq 5) {  
		$self->reassign();	
	}
	elsif ($option eq 6) {  
		$db->flush_screening_db();
	}
	elsif ($option eq 7) {  
		$db->drop_screening_db();    
	}
}

############################################################################
# SECTION: Initialise
############################################################################

#***************************************************************************
# Subroutine:  create_screening_db
# Description: create a screening datbase 
#***************************************************************************
sub create_screening_db {

	my ($self, $ctl_file) = @_;

	# Get parameters
	unless ($ctl_file) { die; }  # Sanity checking
	print "\n\t ### Reading control file\n";
	my $loader_obj = ScreenBuild->new($self);
	$loader_obj->parse_control_file($ctl_file);
	my $db_name = $loader_obj->{db_name};
	unless ($db_name)  { die; } 
		
	my $db_obj = ScreeningDB->new($loader_obj);
	$db_obj->create_screening_db($db_name);	
	$self->{db} = $db_obj; # Store the database object reference 
}

#***************************************************************************
# Subroutine:  initialise 
# Description: do initial checks
#***************************************************************************
sub initialise {

	my ($self, $ctl_file) = @_;
	
	# Initialise
	print "\n\t ### Initialising database-guided genome screening\n";
	
	# Check the size of the process directory
	#$self->check_process_dir_status();
	
	# Get parameters
	print "\n\t ### Reading control file\n";
	my $loader_obj = ScreenBuild->new($self);
	$loader_obj->parse_control_file($ctl_file, $self);

	# Load screening database
	my $db_name = $loader_obj->{db_name};
	unless ($db_name) { die "\n\t Error: no DB name set \n\n\n"; }
	my $db_obj = ScreeningDB->new($self);
	$db_obj->load_screening_db($db_name);	
	$self->{db} = $db_obj; # Store the database object reference 
	
	# Store the loader object initialised with the control file params
	$self->{loader_obj} = $loader_obj;
	$self->{ctl_file}   = $ctl_file;
}

############################################################################
# SECTION: Running a round of bidirectional BLAST screening
############################################################################

#***************************************************************************
# Subroutine:  screen
# Description: run reciprocal BLAST pipeline
#***************************************************************************
sub screen {

	my ($self) = @_;

	# Get relevant member variables and objects
	my $db_ref = $self->{db};
	unless ($db_ref) { die; }  # Sanity checking

	# Set up the screening queries
	print "\n\n\t ### Setting up a DIGS screen";
	my %queries;
	my $loader_obj = $self->{loader_obj};
	unless ($loader_obj) { die; }  # Sanity checking
	my $valid = $loader_obj->set_up_screen($self, \%queries);
	unless ($valid) {
		print "\n\n\t ### Could not create valid screen - check control file\n\n\n";
		exit;
	}

	# Iterate through and excute screens
	print "\n\n\t ### Starting database-guided genome screening\n";
	sleep 2;
	my @probes = keys %queries;
	foreach my $probe_name (@probes) {
		
		# Get the array of queries for this target file
		my $probe_queries = $queries{$probe_name};
		foreach my $query_ref (@$probe_queries) {  
			
			# Show status 
			my $probe_id    = $query_ref->{probe_id};
			my $target_name = $query_ref->{target_name}; # $target refers to the target file
			print "\n\n\t # Screening target $target_name with probe $probe_id ";   
			
			# Do the 1st BLAST (probe vs target)
			$self->search($query_ref);	
			print "\n\t # 1st BLAST step completed, BLAST results table up-to-date...";
	
			# Do the 2nd BLAST (hits from 1st BLAST vs reference library)
			$self->assign($query_ref);
			print "\n\t # 2nd BLAST step completed, Extracted table up-to-date...";

			# Summarise extracted table
			$db_ref->summarise_extracted_table();	
		}	
	}
	
	# Cleanup
	my $output_dir = $loader_obj->{report_dir};
	my $command1 = "rm -rf $output_dir";
	system $command1;

	# Print finished message
	print "\n\n\n\t ### SCREEN COMPLETE ~ + ~ + ~\n\n\n";
}

#***************************************************************************
# Subroutine:  search
# Description: execute a search (i.e. run a BLAST query)
# Arguments:   $query_ref - data structure with the query details
#***************************************************************************
sub search {
	
	my ($self, $query_ref) = @_;

	# Get relevant member variables and objects
	my $db_ref       = $self->{db};
	my $blast_obj    = $self->{blast_obj};
	my $tmp_path     = $self->{tmp_path};
	my $min_length   = $self->{seq_length_minimum};
	my $redundancy_mode = $self->{redundancy_mode};
	unless ($min_length) { $min_length = $default_min_seqlen; }
	
	# Sanity checking
	unless ($blast_obj)       { die; } 
	unless ($tmp_path)        { die; } 
	unless ($redundancy_mode) { die; } 
	unless ($db_ref)          { die; } 

	# Get query details
	my $probe_id     = $query_ref->{probe_id};
	my $probe_name   = $query_ref->{probe_name};
	my $probe_gene   = $query_ref->{probe_gene};
	my $probe_path   = $query_ref->{probe_path};
	my $organism     = $query_ref->{organism};
	my $version      = $query_ref->{version};
	my $data_type    = $query_ref->{data_type};
	my $target_name  = $query_ref->{target_name};
	my $target_path  = $query_ref->{target_path};
	my $blast_alg    = $query_ref->{blast_alg};
	my $cutoff       = $query_ref->{bitscore_cutoff};
	my $result_file  = $tmp_path . "/$probe_id" . "_$target_name.blast_result.tmp";
	#$devtools->print_hash($query_ref); die; # DEBUG	

	# Do the BLAST search
	$blast_obj->blast($blast_alg, $target_path, $probe_path, $result_file);
	
	# Parse out the alignment
	my @hits;
	$blast_obj->parse_tab_format_results($result_file, \@hits, $cutoff);
	
	# Clean up - remove the result file
	my $rm_command = "rm $result_file";
	system $rm_command;

	# Rename coordinate fields to match DB
	foreach my $hit_ref (@hits) {
		$hit_ref->{subject_start} = $hit_ref->{aln_start};
		$hit_ref->{subject_end}   = $hit_ref->{aln_stop};
		$hit_ref->{query_end}     = $hit_ref->{query_stop};
	}

	# Store new new BLAST hits that meet conditions
	my $blast_results_table = $db_ref->{blast_results_table};
	my $i = 0;
	my $num_hits = scalar @hits;
	print "\n\t\t # $num_hits matches to probe: $probe_name, $probe_gene";
	print "\n\t\t # in  $organism, $data_type, $version, '$target_name'";
	foreach my $hit_ref (@hits) {
	
		$i++;
		
		# Skip sequences that are too short
		my $start  = $hit_ref->{subject_start};
		my $end    = $hit_ref->{subject_end};
		if ($end - $start < $min_length) {  next; }
		
		# Record hit in BLAST results table
		$hit_ref->{organism}     = $organism;
		$hit_ref->{version}      = $version;
		$hit_ref->{data_type}    = $data_type;
		$hit_ref->{target_name}  = $target_name;
		$hit_ref->{probe_id}     = $probe_id;
		$hit_ref->{probe_name}   = $probe_name;
		$hit_ref->{probe_gene}   = $probe_gene;
		$hit_ref->{probe_type}   = $query_ref->{probe_type};
		$hit_ref->{hit_length}   = $hit_ref->{align_len};
		if ($verbose) {
			print "\n\t # Match $i to probe: $probe_name, $probe_gene";
			print "\n\t # - in genome: $organism, $data_type, $version";
			print "\n\t # - target file: '$target_name'";
		}
		$blast_results_table->insert_row($hit_ref);
	} 

	# Consolidate the BLAST table based on results
	if ($redundancy_mode > 1) {
		$self->consolidate_hits($query_ref);
	}
	
	# Update the status table
	my $status_table = $db_ref->{status_table};
	$status_table->insert_row($query_ref);
}

############################################################################
# SECTION: Assign 
############################################################################

#***************************************************************************
# Subroutine:  assign
# Description: assign sequences that matched probes in a BLAST search 
#***************************************************************************
sub assign {
	
	my ($self, $query_ref) = @_;
	
	# Get parameters from self
	my $db_ref = $self->{db};
	my $table  = $db_ref->{extracted_table}; 

	# Extract hits 
	my @extracted;
	$self->extract_unassigned_hits($query_ref, \@extracted);	
	
	# Iterate through the matches
	my $assigned_count = 0;
	foreach my $hit_ref (@extracted) {

		# Set the linking to the BLAST result table
		my $blast_id  = $hit_ref->{record_id};
		$hit_ref->{blast_id} = $blast_id;
		
		# Execute the 'reverse' BLAST (2nd BLAST in a round of bidirectional BLAST)	
		my %data = %$hit_ref; # Make a copy
		$self->do_reverse_blast(\%data);
		$assigned_count++;

		# Insert the data
		my $extract_id = $table->insert_row(\%data);
	}

	# Number of table rows in BLAST and Extracted tables should be equal
	my $db = $self->{db};
	my $blast_count     = $db->count_blast_rows();
	my $extracted_count = $db->count_extracted_rows();
	print "\n\t # Assigned $assigned_count newly extracted sequences";
	unless ($blast_count eq $extracted_count) { 
		print "\n\t # Extracted $extracted_count, BLAST_results count $blast_count";
		die "\n\n\t\t ###### UNEVEN TABLE COUNT ERROR\n\n\n";
	}
}

#***************************************************************************
# Subroutine:  reverse BLAST
# Description: Execute the 2nd BLAST in a round of bidirectional BLAST
#***************************************************************************
sub do_reverse_blast {

	my ($self, $hit_ref) = @_;
	
	# Get paths and objects from self
	my $result_path   = $self->{tmp_path};
	my $blast_obj     = $self->{blast_obj};
	unless ($result_path and $blast_obj) { die; }
	
	# Copy the coordinates AS EXTRACT coordinates	
	my $extract_start = $hit_ref->{subject_start};
	my $extract_end   = $hit_ref->{subject_end};
	my $blast_id      = $hit_ref->{blast_id};
	my $sequence      = $hit_ref->{sequence};
	my $organism      = $hit_ref->{organism};
	my $probe_type    = $hit_ref->{probe_type};
	
	# Sanity checking
	unless ($sequence) {  die "\n\t # No sequence found in revsre BLAST"; } 
	
	# Make a file for BLAST
	my $fasta      = ">$blast_id\n$sequence";
	my $query_file = $result_path . $blast_id . '.fas';
	$fileio->write_text_to_file($query_file, $fasta);
	my $result_file = $result_path . $blast_id . '.blast_result';
		
	# Do the BLAST according to the type of sequence (AA or NA)
	my $blast_alg;
	my $lib_path;
	unless ($probe_type) { die; }
	if ($probe_type eq 'UTR') {
		$lib_path  = $self->{blast_utr_lib_path};
		$blast_alg = 'blastn';
	}
	elsif ($probe_type eq 'ORF') {
		$lib_path  = $self->{blast_orf_lib_path};
		$blast_alg = 'blastx';
	}
	else { die; }

	# Execute the 'reverse' BLAST (2nd BLAST in a round of bidirectional BLAST)	
	unless ($lib_path) { die "\n\n\t NO BLAST LIBRARY defined\n\n\n"; }
	$blast_obj->blast($blast_alg, $lib_path, $query_file, $result_file);
	my @results;
	$blast_obj->parse_tab_format_results($result_file, \@results);

	# Get the best match from this file
	my $top_match = shift @results;
	my $query_start   = $top_match->{query_start};
	my $query_end     = $top_match->{query_stop};
	my $subject_start = $top_match->{aln_start};
	my $subject_end   = $top_match->{aln_stop};
	my $assigned_name = $top_match->{scaffold};	
	#$devtools->print_hash($top_match); # DEBUG
	
	unless ($assigned_name) {	
		
		print "\n\t ### No match found in reference library\n";
		$hit_ref->{assigned_name}    = 'Unassigned';
		$hit_ref->{assigned_gene}    = 'Unassigned';
		$hit_ref->{extract_start}    = 0;
		$hit_ref->{extract_end}      = 0;
		$hit_ref->{identity}         = 0;
		$hit_ref->{bit_score}        = 0;
		$hit_ref->{e_value_exp}      = 0;
		$hit_ref->{e_value_num}      = 0;
		$hit_ref->{mismatches}       = 0;
		$hit_ref->{align_len}        = 0;
		$hit_ref->{gap_openings}     = 0;
		$hit_ref->{query_end}        = 0;
		$hit_ref->{query_start}      = 0;
		$hit_ref->{subject_end}      = 0;
		$hit_ref->{subject_start}    = 0;
	}
	else {	

		# Split assigned to into (i) refseq match (ii) refseq description (e.g. gene)	
		my @assigned_name = split('_', $assigned_name);
		my $assigned_gene = pop @assigned_name;
		$assigned_name = join ('_', @assigned_name);
		#print " assigned to: $assigned_name: $assigned_gene!";
		$hit_ref->{assigned_name}    = $assigned_name;
		$hit_ref->{assigned_gene}    = $assigned_gene;
		$hit_ref->{extract_start}    = $extract_start;
		$hit_ref->{extract_end}      = $extract_end;
		$hit_ref->{identity}         = $top_match->{identity};
		$hit_ref->{bit_score}        = $top_match->{bit_score};
		$hit_ref->{e_value_exp}      = $top_match->{e_value_exp};
		$hit_ref->{e_value_num}      = $top_match->{e_value_num};
		$hit_ref->{mismatches}       = $top_match->{mismatches};
		$hit_ref->{align_len}        = $top_match->{align_len};
		$hit_ref->{gap_openings}     = $top_match->{gap_openings};
		$hit_ref->{query_end}        = $query_end;
		$hit_ref->{query_start}      = $query_start;
		$hit_ref->{subject_end}      = $subject_end;
		$hit_ref->{subject_start}    = $subject_start;
	}

	# Clean up
	my $command1 = "rm $query_file";
	my $command2 = "rm $result_file";
	system $command1;
	system $command2;
}

#***************************************************************************
# Subroutine:  extract_unassigned_hits
# Description: extract BLAST hit sequences that are not in Extracted table
#***************************************************************************
sub extract_unassigned_hits {
	
	my ($self, $query_ref, $extracted_ref) = @_;

	# Get paths, objects, data structures and variables from self
	my $blast_obj   = $self->{blast_obj};
	my $target_path = $query_ref->{target_path};
	my $target_name = $query_ref->{target_name};
	my $db_ref      = $self->{db};
	my $blast_results_table = $db_ref->{blast_results_table};

	# Index extracted BLAST results 
	my %extracted;
	my $where = " WHERE target_name = '$target_name' ";
	$db_ref->index_extracted_loci_by_blast_id(\%extracted, $where);

	# Get hits we are going to extract
	my @hits;
	$db_ref->get_blast_hits_to_extract($query_ref, \@hits);
	my $num_hits = scalar @hits;
	#print "\n\t ### There are $num_hits hits to extract";

	# Store all outstanding matches as sequential, target-ordered sets 
	foreach my $hit_ref (@hits) {
		
		# Skip previously extracted hits
		my $record_id   = $hit_ref->{record_id};
		if ($verbose) {
			print "\n\t Checking $record_id in extracted table";
		}
		if ($extracted{$record_id}) { 
			if ($verbose) {
				print "\t ALREADY EXTRACTED";
			}
			next;
		 }
		
		# Extract the sequence
		my $sequence = $blast_obj->extract_sequence($target_path, $hit_ref);
		if ($sequence) {	
			if ($verbose) {
				print "\t ........extracting";
			}
			my $seq_length = length $sequence; # Set sequence length
			$hit_ref->{sequence_length} = $seq_length;
			$hit_ref->{sequence} = $sequence;
			push (@$extracted_ref, $hit_ref);
		}
		else {
			if ($verbose) {
				print "\n\t Sequence extraction failed";
			}
		}
	}
	#my $num_extracted = scalar @$extracted_ref;	
	#print "\n\t Num extracted $num_extracted";	
}

#***************************************************************************
# Subroutine:  reassign
# Description: reassign sequences in the extracted_table (for use after
#              the reference library has been updated)
#***************************************************************************
sub reassign {
	
	my ($self) = @_;

	# Set up to perform the reassign process
	print "\n\t # Reassigning Extracted table";
	my @assigned_seqs;
	$self->initialise_reassign(\@assigned_seqs);

	# Get data structures and variables from self
	my $blast_obj       = $self->{blast_obj};
	my $result_path     = $self->{report_dir};
	my $db              = $self->{db};
	my $extracted_table = $db->{extracted_table};
	unless ($extracted_table) { die; }
	
	# Iterate through the matches
	foreach my $hit_ref (@assigned_seqs) {

		# Set the linking to the BLAST result table
		my $blast_id  = $hit_ref->{record_id};
		$hit_ref->{blast_id} = $blast_id;
		delete $hit_ref->{record_id};
		my $extract_start   = $hit_ref->{extract_start};
		my $extract_end     = $hit_ref->{extract_end};
		$hit_ref->{subject_start} = $extract_start;
		$hit_ref->{subject_end}   = $extract_end;
		delete $hit_ref->{extract_start};
		delete $hit_ref->{extract_end};
	
		# Execute the 'reverse' BLAST (2nd BLAST in a round of bidirectional BLAST)	
		my $previous_assign = $hit_ref->{assigned_name};
		my $previous_gene   = $hit_ref->{assigned_gene};
		print "\n\t Redoing assign for record ID $blast_id assigned to $previous_assign";
		print "\n\t coordinates: $extract_start-$extract_end";
		$self->do_reverse_blast($hit_ref);
		
		my $assigned_name = $hit_ref->{assigned_name};
		my $assigned_gene = $hit_ref->{assigned_gene};
		if ($assigned_name ne $previous_assign 
		or  $assigned_gene ne $previous_gene) {
			
			# Insert the data
			print "\n\t ##### Reassigned $blast_id from $previous_assign ($previous_gene)";
			print " to $assigned_name ($assigned_gene)";
			my $where = " WHERE Record_id = $blast_id ";
			$extracted_table->update($hit_ref, $where);
		}
	}
	# Cleanup
	my $output_dir = $self->{report_dir};
	my $command1 = "rm -rf $output_dir";
	system $command1;
}

#***************************************************************************
# Subroutine:  initialise_reassign 
# Description: set up for reassigning the sequences in the Extracted table
#***************************************************************************
sub initialise_reassign {

	my ($self, $assigned_seqs_ref) = @_;

	# Create a unique ID and report directory for this run
	my $output_path = $self->{output_path};
	my $process_id  = $self->{process_id};
	my $db          = $self->{db};
	my $db_name     = $db->{db_name};
	unless ($db and $db_name and $process_id and $output_path) { die; }
	
	# Create report directory
	my $loader_obj = $self->{loader_obj};
	$loader_obj->create_output_directories($self);

	# Get the assigned data
	my $extracted_table = $db->{extracted_table};
	my @fields  = qw [ record_id probe_type assigned_name assigned_gene 
	                       extract_start extract_end sequence organism ];
	$extracted_table->select_rows(\@fields, $assigned_seqs_ref);

	# Set up the reference library
	if ($loader_obj->{reference_aa_fasta}) {
		$loader_obj->load_aa_fasta_reference_library();
	}
	if ($loader_obj->{reference_nt_fasta}) {
		$loader_obj->load_nt_fasta_reference_library();
	}

	# Transfer parameters from loader to this obj
	$self->{seq_length_minimum}    = $loader_obj->{seq_length_minimum};
	$self->{bit_score_min_tblastn} = $loader_obj->{bit_score_min_tblastn};
	$self->{bit_score_min_blastn}  = $loader_obj->{bit_score_min_blastn};
	$self->{blast_orf_lib_path}    = $loader_obj->{blast_orf_lib_path};
	$self->{blast_utr_lib_path}    = $loader_obj->{blast_utr_lib_path};
}

############################################################################
# SECTION: Retrieve data from screening database
############################################################################

#***************************************************************************
# Subroutine:  retrieve 
# Description: retrieve data from screening database
#***************************************************************************
sub retrieve {

	my ($self, $ctl_file) = @_;

	# Get params from self	
	my $select = $self->{select_list};
	my $where  = $self->{where_statement};
	unless ($select) { die; }

	my $db = $self->{db};
	my @select;
	my @tmp  = split(/,/, $select);
	foreach my $field (@tmp) {
		$field =~ s/\s+//;
		push (@select, $field);
	}
	#$devtools->print_array(\@select); die;

	# Get params from self	
	my @sequences;
	$db->retrieve_sequences(\@sequences, \@select, $where);
	my $seqfile = 'sequences.fa';
	$fileio->write_file($seqfile, \@sequences);
}

############################################################################
# SECTION: Consolidate Fxns
############################################################################

#***************************************************************************
# Subroutine:  consolidate_hits
# Description: Consolidate the BLAST table based on results
#***************************************************************************
sub consolidate_hits {
	
	my ($self, $query_ref) = @_;

	# Get relevant member variables and objects
	my $db_ref  = $self->{db};
	my $blast_results_table = $db_ref->{blast_results_table};

	# Set the fields to get values for
	my @fields = qw [ record_id scaffold orientation
	                  subject_start subject_end
                      query_start query_end ];

	# Get the information for this query
	my $target_name = $query_ref->{target_name};
	my $probe_name  = $query_ref->{probe_name};
	my $probe_gene  = $query_ref->{probe_gene};

	my $where  = " WHERE target_name = '$target_name'";

	# Filter by gene name 
	if ($self->{redundancy_mode} eq 2) {
		$where .= " AND probe_gene = '$probe_gene' ";
	}
	elsif ($self->{redundancy_mode} eq 3) {
		$where .= " AND probe_name = '$probe_name'
                    AND probe_gene = '$probe_gene' ";
	}

	# Order by ascending start coordinates within each scaffold in the target file
	$where .= "ORDER BY scaffold, subject_start ";
	
	# Get the relevant loci
	my @hits;
	$blast_results_table->select_rows(\@fields, \@hits, $where);

	# Iterate through consolidating as we go
	my $i;
	my %last_hit;
	my %consolidated;
	my %retained;
	my $consolidated_count = 0;
	foreach my $hit_ref (@hits)  {

		# Get hit values
		$i++;
		my $record_id     = $hit_ref->{record_id};
		my $scaffold      = $hit_ref->{scaffold};
		my $orientation   = $hit_ref->{orientation};
		my $subject_start = $hit_ref->{subject_start};
		
		# Get last hit values
		my $last_record_id     = $last_hit{record_id};
		my $last_scaffold      = $last_hit{scaffold};
		my $last_orientation   = $last_hit{orientation};
		my $consolidated;

		if ($verbose) {
			print "\n\t $subject_start: RECORD ID $record_id";
		}

		# Keep if first in this loop process
		if ($i eq 1) {
			$retained{$record_id} = 1;
		}
		# ...or if first hit on scaffold
		elsif ($scaffold ne $last_scaffold) {
			$retained{$record_id} = 1;
		}
		# ...or if in opposite orientation to last hit
		elsif ($orientation ne $last_orientation) {
			$retained{$record_id} = 1;
		}
		else { # If we get this far we have two hits on the same scaffold
			
			# Check whether to consolidate hit on the same target scaffold
			$consolidated = $self->inspect_adjacent_hits(\%last_hit, $hit_ref);

			# Keep track of the outcome
			if ($consolidated) {
				$consolidated_count++;
				my %hit = %last_hit; # Make a copy
				$hit{hit_length} = ($hit{subject_end} - $hit{subject_start}) + 1;
				$consolidated{$record_id} = \%hit;
				$retained{$last_record_id} = 1;
			}
			else {
				$retained{$record_id} = 1;
			}
		}
		
		# Update the 'last hit' to the current one before exiting this iteration
		unless ($consolidated) {
			$last_hit{record_id}     = $record_id;
			$last_hit{scaffold}      = $scaffold;
			$last_hit{orientation}   = $orientation;
			$last_hit{subject_start} = $hit_ref->{subject_start};
			$last_hit{subject_end}   = $hit_ref->{subject_end};
			$last_hit{query_start}   = $hit_ref->{query_start};
			$last_hit{query_end}     = $hit_ref->{query_end};
		}
	}
	# Update BLAST table
	$self->update_db_loci(\@hits, \%retained, \%consolidated);
}

#***************************************************************************
# Subroutine:  inspect_adjacent_hits
# Description: determine whether two adjacent hits should be joined
#***************************************************************************
sub inspect_adjacent_hits {
	
	my ($self, $last_hit_ref, $hit_ref) = @_;

	# Get parameters for consolidating hits from self
	my $probe_buffer = $self->{threadhit_probe_buffer};
	my $gap_buffer   = $self->{threadhit_gap_buffer};
	my $max_gap      = $self->{threadhit_max_gap};
	unless ($probe_buffer and $gap_buffer and $max_gap) { die; } 

	# Get data for 1st hit (i.e. most 'leftward' in the target sequence)
	my $last_record_id     = $last_hit_ref->{record_id};
	my $last_subject_start = $last_hit_ref->{subject_start};
	my $last_subject_end   = $last_hit_ref->{subject_end};
	my $last_query_start   = $last_hit_ref->{query_start};
	my $last_query_end     = $last_hit_ref->{query_end};
	
	# Get data for 2nd hit (most 'rightward' in the target sequence)
	my $record_id          = $hit_ref->{record_id};
	my $scaffold           = $hit_ref->{scaffold};
	my $orientation        = $hit_ref->{orientation};
	my $subject_start      = $hit_ref->{subject_start};
	my $subject_end        = $hit_ref->{subject_end};
	my $query_start        = $hit_ref->{query_start};
	my $query_end          = $hit_ref->{query_end};

	# Calculate the gap between these sequences on the target sequences
	my $subject_gap = $subject_start - $last_subject_end;
	#print "\n\n\t #### Checking whether to consolidate $last_record_id and $record_id on $scaffold";
	#print "\n\t #### Q Last:  $last_query_start\t $last_query_end";
	#print "\n\t #### S Last:  $last_subject_start\t $last_subject_end";
	#print "\n\t #### Q This:  $query_start\t $query_end";
	#print "\n\t #### S This:  $subject_start\t $subject_end";
	#print "\t #### Gap:   $subject_gap\n";


	# Calculate the gap between the query coordinates of the two matches
	# Note this may be a negative number if the queries overlap 
	my $query_gap;
	if ($orientation eq '+ve') {
		$query_gap = $query_start - $last_query_end;
	}
	elsif ($orientation eq '-ve') {
		$query_gap = $last_query_start - $query_end;
	}
	
	### Deal with contingencies that mean hits definitely should or should not be consolidate
	#   Hit is entirely within a previous hit it is redundant
	if ($last_subject_start <= $subject_start and $last_subject_end >= $subject_end) {
		return 1; # Effectively discarding current hit
	}
	#   Hits are too far apart
	elsif ($max_gap) {
		if ($subject_gap > $max_gap) {
			return 0;  
		}
	}

	### Deal with situations where hits are partially (but not completely) overlapping
	#   or where they are close enough to each other consider consolidating them






	
	# What is this??????	
	my $buffer_start = $query_start + $probe_buffer;

	if ($subject_gap < 1) {
		# Describe the consolidation:
		if ($verbose) {
			print "\t    SUBJECT GAP: Merged hit $record_id into hit $last_record_id (subject_gap: $subject_gap)";
		}
		$last_hit_ref->{subject_end} = $hit_ref->{subject_end};
		$last_hit_ref->{query_end}   = $hit_ref->{query_end};
		return 1;  # Consolidated (joined) hits
	}
	

	# For positive orientation hits
	# If the query_start of this hit < query_end of the last, then its a distinct hit
	elsif ($orientation eq '+ve' and $buffer_start < $last_query_end) {
		if ($verbose) {
			print "\n\t    DISTINCT +ve: start $query_start (buffer $buffer_start) is too much less than end of last query ($last_query_end) \tsubject gap: $subject_gap";
		}
		return 0;
	}
	# For negative orientation hits
	# If the query_start of this hit < query_end of the last, then its a distinct hit
	elsif ($orientation eq '-ve' and ($last_query_start - $query_end) > $probe_buffer ) {
		if ($verbose) {
			print "\n\t    DISTINCT -ve: ($last_query_start - $query_end) > $probe_buffer \tsubject gap: $subject_gap";
		}
		return 0;
	}
	# If not, then check the intervening distance between the hits
	else {

		my $nt_query_gap = $query_gap * 3;
		if (($subject_gap - $nt_query_gap) < $gap_buffer) {
			# Describe the consolidation:
			if ($verbose) {
				print "\n\t    Merged hit $record_id into hit $last_record_id: subject gap ($subject_gap) nt query gap ($nt_query_gap) ";
			}
			$last_hit_ref->{subject_end} = $hit_ref->{subject_end};
			$last_hit_ref->{query_end}   = $hit_ref->{query_end};
			return 1;  # Consolidated (joined) hits
		}
		else {
			if ($verbose) {
				print "\n\t    DISTINCT LAST: start $query_start (buffer $buffer_start) is too much less than end of last query ($last_query_end) \tsubject gap: $subject_gap";
			}
			return 0;  # Distinct hit
		}
	}




}

#***************************************************************************
# Subroutine:  update_db_loci  
# Description:
#***************************************************************************
sub update_db_loci {
	
	my ($self, $hits_ref, $retained_ref, $consolidated_ref) = @_;

	# Get relevant member variables and objects
	my $db_ref  = $self->{db};
	my $blast_results_table = $db_ref->{blast_results_table};
	my $extracted_table     = $db_ref->{extracted_table};

	# Delete redundant rows from BLAST results
	my $blast_deleted = 0;
	my $extract_deleted = 0;
	foreach my $hit_ref (@$hits_ref)  {
		my $record_id = $hit_ref->{record_id};
		unless ($retained_ref->{$record_id}) {
			# Delete rows
			#print "\n\t ## deleting hit record ID $record_id in BLAST results";
			my $where = " WHERE record_id = $record_id ";
			$blast_results_table->delete_rows($where);
			$blast_deleted++;

			#print "\n\t ## deleting hit BLAST ID $record_id in Extracted";
			my $ex_where = " WHERE blast_id = $record_id ";
			$extracted_table->delete_rows($ex_where);
			$extract_deleted++;
		}
		else { 
			#print "\n\t ## keeping hit $record_id";
		}
	}

	# Update BLAST table with consolidated hits
	my $blast_updated = 0;
	my @ids = keys %$consolidated_ref;
	foreach my $record_id (@ids)  {

		my $where   = " WHERE record_id = $record_id ";
		my $hit_ref = $consolidated_ref->{$record_id};		
		delete $hit_ref->{record_id};
		#print "\n\t ## updating hit record ID $record_id in BLAST results";
		$blast_results_table->update($hit_ref, $where);
		$blast_updated++;
		
		# Delete from Extracted (because we need to re-extract and assign)
		#print "\n\t ## deleting hit BLAST ID $record_id in Extracted";
		my $ex_where = " WHERE blast_id = $record_id ";
		$extracted_table->delete_rows($ex_where);
		$extract_deleted++;
	}
}

############################################################################
# SECTION: Utility Fxns
############################################################################

#***************************************************************************
# Subroutine:  check_process_dir_status
# Description: check the size of the process directory and warn if it is
#              getting very large 
#***************************************************************************
sub check_process_dir_status {

	my ($self) = @_;

	# Read in the process directory
	my $output_path = $self->{output_path};
	unless ($output_path) { die; }

	my @process_dir;
	$fileio->read_directory_to_array($output_path, @process_dir);
	my $num_folders = scalar @process_dir;

	if ($num_folders > $process_dir_warn) {
		print "\n\t ### Process directory '$output_path' contains > $process_dir_warn items";
		print "\n\t #     consider cleaning up the contents.";
		sleep 2;
	}
}

#***************************************************************************
# Subroutine:  show_title
# Description: show command line title blurb 
#***************************************************************************
sub show_title {

	$console->refresh();
	my $title       = 'Database-Integrated Genome Screening (DIGS)';
	my $version     = '1.0';
	my $description = 'Sequence database screening using BLAST and MySQL';
	my $author      = 'Robert J. Gifford';
	my $contact	    = '<robert.gifford@glasgow.ac.uk>';
	$console->show_about_box($title, $version, $description, $author, $contact);
}

############################################################################
# EOF
############################################################################
