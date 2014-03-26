#!/usr/bin/perl -w
############################################################################
# Script:      pipeline.pl 
# Description: control script for DIGS
# History:     Version 1.0 Creation: Rob J Gifford 2014
############################################################################

unless ($ENV{GENOMES}) {
	print  "\n\n\t PLEASE DEFINE '\$GENOMES' (Path to genome data directory)\n\n\n";
	exit;
}
# Include a local library of PERL modules 
use lib './modules/'; 

############################################################################
# Import statements/packages (externally developed packages)
############################################################################
use strict;
use CGI;
use Getopt::Long;

############################################################################
# Import statements/packages (internally developed packages)
############################################################################

# Base modules
use Base::Console;
use Base::DevTools;
use Base::FileIO;

# Third party program interface modules
use Interface::BLAST;   # Interface to BLAST 

# Paleovirology program modules
use DIGS::Pipeline;
use DIGS::ScreenBuild;
use DIGS::GenomeControl;
use DIGS::DB;

############################################################################
# Paths & Globals
############################################################################

# Paths
my $blast_bin_path        = '';              # path to directory with BLAST+ programs
                                             # leave blank if BLAST+ programs in path 
#my $blast_bin_path       = './bin/blast/';      
my $genome_use_path       = $ENV{GENOMES};   # genome data directory
my $output_path           = './';            # default write results to same directory as script
	
# Process ID and time - used to create a unique ID for each program run
my $pid  = $$;
my $time = time;
my $process_id   = 'result_set_' . $pid . '_' . $time;

############################################################################
# Instantiations for program 'classes' (PERL's Object-Oriented Emulation)
############################################################################

# Base utilites
my $seqio      = SeqIO->new();
my $fileio     = FileIO->new();
my $devtools   = DevTools->new();
my $console    = Console->new();

# Interface to BLAST
my %blast_params;
$blast_params{blast_bin_path} = $blast_bin_path;
my $blast_obj = BLAST->new(\%blast_params);

# Instantiate main program classes using global settings
my %params;
$params{process_id}         = $process_id;
$params{blast_bin_path}     = $blast_bin_path; 
$params{genome_use_path}    = $genome_use_path;
$params{output_path}        = $output_path; 
$params{blast_obj}          = $blast_obj;
my $pipeline_obj = Pipeline->new(\%params);

############################################################################
# Set up USAGE statement
############################################################################

# Initialise usage statement to print if usage is incorrect
my ($USAGE)  = "\n\t #### DIGS Tool:\n";
    $USAGE  .= "\n\t usage: $0 -m=[option] -i=[control file]\n";
  	$USAGE  .= "\n\t -m=1  create a screening DB"; 
  	$USAGE  .= "\n\t -m=2  execute a round of bidirectional BLAST screening"; 
  	$USAGE  .= "\n\t -m=3  summarise a screening DB"; 
  	$USAGE  .= "\n\t -m=4  retrieve FASTA sequences from a screening DB"; 
  	$USAGE  .= "\n\t -m=5  reassign sequences after reference sequence library update"; 
  	$USAGE  .= "\n\t -m=6  flush a screening DB"; 
  	$USAGE  .= "\n\t -m=7  drop a screening DB"; 
  	$USAGE  .= "\n\t -m=8  summarise genome data in the target genome directory"; 
 	$USAGE  .= "\n\n";

############################################################################
# Main program
############################################################################

# Run script
main();

# Exit program
print "\n\n\t DONE\n\n\n";
exit;

############################################################################
# Subroutines
############################################################################

#***************************************************************************
# Subroutine:  main
# Description: top level handler fxn
#***************************************************************************
sub main {
	
	# Show title
	$pipeline_obj->show_title();

	# Read in options using GetOpt::Long
	my $mode    = undef;
	my $infile  = undef;
	GetOptions ('mode|m=i'   => \$mode, 
			    'infile|i=s' => \$infile,
	) or die $USAGE;

	# Sanity checking for input 
	if ($mode) {
		unless ($mode > 0 and $mode <= 8) { die $USAGE; }
		if ($mode ne 8) {
			unless ($mode and $infile)    { die $USAGE; }
		}
	}
	else {
		die $USAGE;
	}
	
	# Hand off to Pipeline.pm
	$pipeline_obj->run_digs_function($mode, $infile); 

}

############################################################################
# End of file 
############################################################################
