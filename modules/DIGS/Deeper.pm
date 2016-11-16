#!usr/bin/perl -w
############################################################################
# Module:      Deeper.pm
# Description: Analysis routines for databases generated by DIGS
# History:     December 2016: Created by Robert Gifford 
############################################################################
package Deeper;

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

############################################################################
# Globals
############################################################################

# Base objects
my $fileio    = FileIO->new();
my $console   = Console->new();
my $devtools   = DevTools->new();
1;

############################################################################
# LIFECYCLE
############################################################################

#***************************************************************************
# Subroutine:  new
# Description: create new Deeper 'object'
#***************************************************************************
sub new {

	my ($invocant, $parameter_ref) = @_;
	my $class = ref($invocant) || $invocant;

	# Set member variables
	my $self = {
		
		# Flags
		process_id             => $parameter_ref->{process_id},
		program_version        => $parameter_ref->{program_version},
		
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
# TOP LEVEL HANDLER
############################################################################

#***************************************************************************
# Subroutine:  run_digs_analysis
# Description: handler for main Deeper functions 
#***************************************************************************
sub run_digs_analysis {

	my ($self, $option, $analysis_file) = @_;

	unless ($analysis_file)  {  die "\n\t Analysis option '$option' requires an infile\n\n"; }

 	# Show title
	$self->initialise_analysis($analysis_file);

	# Get summary counts
	$self->summarise_db_counts();

	# Write counts
	$self->write_db_counts();	
}

#***************************************************************************
# Subroutine:  initialise analysis
# Description: initialise module for analysis
#***************************************************************************
sub initialise_analysis {

	my ($self, $analysis_file) = @_;

	# Try opening control file
	my @analysis_file;
	my $valid = $fileio->read_file($analysis_file, \@analysis_file);
	unless ($valid) {  # Exit if we can't open the file
		die "\n\t ### Couldn't open analysis file '$analysis_file'\n\n\n ";
	}

	# If control file looks OK, store the path and parse the file
	$self->{analysis_file}   = $analysis_file;

	# Read analysis file
	$valid = $fileio->read_file($analysis_file, \@analysis_file);
	unless ($valid) { die "\n\t ### Couldn't read analysis file '$analysis_file'\n\n\n "; }
	
	# Parse the 'ANALYSIS' block
	my $start = 'BEGIN ANALYSIS';
	my $stop  = 'ENDBLOCK';
	my $block = $fileio->read_standard_field_value_block(\@analysis_file, $start, $stop, $self);
	unless ($block)  {
		die "\n\n\t Control file error: no 'ANALYSIS' block found\n\n\n";
	}	
	#print "\n\t targets path: $target_genomes_path";
	#print "\n\t targets path: $target_dbs_path\n\n";


	# Parse the 'SCREENDB' block
	$start = 'BEGIN SCREENDB';
	$stop  = 'ENDBLOCK';
	my $db_block = $fileio->read_standard_field_value_block(\@analysis_file, $start, $stop, $self);
	unless ($db_block)  {
		die "\n\t Control file error: no 'SCREENDB' block found\n\n\n";
	}
	
	# Get the 'SCREENDB' block values and validate
	my $server   = $self->{mysql_server};
	my $user     = $self->{mysql_username};
	my $password = $self->{mysql_password};
	unless ($server)  {
		die "\n\t Control file error: 'mysql_server' undefined in 'SCREENDB' block\n\n\n";
	}
	unless ($user)  {
		die "\n\t Control file error: 'mysql_username' undefined in 'SCREENDB' block\n\n\n";
	}
	unless ($password)  {
		die "\n\t Control file error: 'mysql_password' undefined in 'SCREENDB' block\n\n\n";
	}


	# Get the 'ANALYSIS' block values and validate
	my $target_genomes_path = $self->{target_genomes_path};	
	my $target_dbs_path     = $self->{target_dbs_path};	

	# Read the target genomes
	my @target_file;
	$valid = $fileio->read_file($target_genomes_path, \@target_file);
	unless ($valid) { die "\n\t ### Couldn't read targets file '$analysis_file'\n\n\n "; }
	my $header_line = shift(@target_file); # Remove header line	
	my %screen_settings;
	my @targets;
	foreach my $line (@target_file) {

		chomp $line;
		my @line = split ("\t", $line);
		my $species_name = shift @line;
		my $version      = shift @line;

		my %target;
		$target{organism} = $species_name;
		$target{version}  = $version;

		push (@targets, \%target);		

	}
	$screen_settings{target_genomes} = \@targets;
	#$devtools->print_array(\@targets); exit;
		

	# Read the file with target databases and other parameters
	my @db_file;
	$valid = $fileio->read_file($target_dbs_path, \@db_file);
	unless ($valid) { die "\n\t ### Couldn't read db file '$analysis_file'\n\n\n "; }
	$header_line = shift(@db_file); # Remove header line	
	my @screening_dbs;
	# Iterate through the file
	foreach my $line (@db_file) {

		chomp $line;
		my @line = split ("\t", $line);
		my %db_params;
		$db_params{db_name}     = shift @line;
		$db_params{select_gene} = shift @line;
		$db_params{bitscore_cutoff} = shift @line;
		push (@screening_dbs, \%db_params);		

	}
	#$devtools->print_array(\@screening_dbs); exit;
	$screen_settings{screening_dbs} = \@screening_dbs;

	#$devtools->print_hash(\%screen_settings); exit;
	$self->{screen_settings} = \%screen_settings;

}

#***************************************************************************
# Subroutine:  summarise_db_counts
# Description: 
#***************************************************************************
sub summarise_db_counts {

	my ($self) = @_;

	my $screen_settings = $self->{screen_settings};
	
	my $screening_dbs  = $screen_settings->{screening_dbs};
	my $target_genomes = $screen_settings->{target_genomes};
	unless ($screening_dbs and $target_genomes) { die; }
	
	# Iterate through the analysis queries
	my %result_set;
	foreach my $db_params_ref (@$screening_dbs) {
	
		# Get params for this screening database
		my $db_name         = $db_params_ref->{db_name};
		my $select_gene     = $db_params_ref->{select_gene};
		my $bitscore_cutoff = $db_params_ref->{bitscore_cutoff};
		unless ($db_name and $select_gene) { die; }
	
		# Connect to the database 
		my $server   = $self->{mysql_server};
		my $user     = $self->{mysql_username};
		my $password = $self->{mysql_password};
		my %results;
		
		my $dbh = DBI->connect("dbi:mysql:$db_name:$server", $user, $password);
		unless ($dbh) {	die "\n\t # Couldn't connect to $db_name database\n\n"; }
		else {
			print  "\n\t # Connected to $db_name database\n";
		}

		# Iterate through the genomes 
		foreach my $genome_version (@$target_genomes) {
		
			my $organism = $genome_version->{organism};
			my $version  = $genome_version->{version};
			#print "\n\t ORGANISM '$organism', VERSION = '$version'";
				
			unless ($organism and $version) { die; }
			$organism =~ s/ /_/g;
			
			my @gene_count;
			my $sql_command;
			$sql_command = "SELECT DISTINCT Organism, Version, Assigned_name, Assigned_gene, COUNT(*) AS Number ";
			$sql_command .= "FROM Extracted ";
			$sql_command .= "WHERE Organism = '$organism' ";
			$sql_command .= "AND Version = '$version' ";
			$sql_command .= "AND Assigned_gene = '$select_gene' ";
			$sql_command .= "GROUP BY Organism, Version, Assigned_name, Assigned_gene";
			#print "\n\t$sql_command\n";
			#exit;
			
			my $sth = $dbh->prepare($sql_command);
			unless ($sth->execute()) { print $sql_command; exit; }

			# Get the count value from the results
			my $count;
			my $row_count = 0;
			my $key = $organism . $version;
 			while (my $row = $sth->fetchrow_arrayref) {	
				$row_count++;
				$count = @$row[4];
				unless ($count) {  die; }
			}
			unless ($row_count) { $count = '0'; }
			elsif ($row_count > 1) { die; }
			print "\n\t # Got value '$count' for key '$key'";

			$results{$key} = $count;
		}	
		# Store this DB result set
		print "\n\t # Storing results for '$db_name' in results hash";
		$result_set{$db_name} = \%results;
	}

	$self->{result_set} = \%result_set;
	
}

#***************************************************************************
# Subroutine:  summarise_db_counts
# Description: 
#***************************************************************************
sub write_db_counts {

	my ($self) = @_;

	my $screen_settings = $self->{screen_settings};
	my $screening_dbs  = $screen_settings->{screening_dbs};
	my $target_genomes = $screen_settings->{target_genomes};
	unless ($screening_dbs and $target_genomes) { die; }
	
	my $result_set_ref = $self->{result_set};
	
	# Write out the combined results
	my @output;

    # Write a header row 
    my $header_line =  "Species\tVersion";
    foreach my $db_params_ref (@$screening_dbs) {
    
        #print "\n\t Writing results for '$db_name'";       
        my $db_name = $db_params_ref->{db_name};
        $header_line .= "\t$db_name";
    }   
    $header_line .= "\n";
    push (@output, $header_line);

	# Iterate through the genomes 
	foreach my $genome_version (@$target_genomes) {
		
		my $organism = $genome_version->{organism};
		$organism =~ s/ /_/g;
		my $version  = $genome_version->{version};
		my $row = "$organism\t$version\t";

		foreach my $db_params_ref (@$screening_dbs) {
	
			#print "\n\t Writing results for '$db_name'";		
			my $db_name = $db_params_ref->{db_name};
			my $results_ref = $result_set_ref->{$db_name};
			#$devtools->print_hash($results_ref); die;
			my $key = $organism . $version;
			my $value = $results_ref->{$key};
			unless ($value) { 
				$row .= "\t0";
			}
			else {
				print "\n\t # Wrote value '$value' for key '$key'";
				$row .= "\t$value";
			}
		
		}
		#print "\n\t ROW: $row";
		push (@output, "$row\n");

	}	
	$fileio->write_file('output.txt', \@output);

}


############################################################################
# EOF
############################################################################
