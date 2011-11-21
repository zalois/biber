package Biber::Utils;
use 5.014000;
use strict;
use warnings;
use re 'eval';
use base 'Exporter';

use constant {
  EXIT_OK => 0,
  EXIT_ERROR => 2
};

use Carp;
use Encode;
use File::Find;
use File::Spec;
use IPC::Cmd qw( can_run );
use IPC::Run3; # This works with PAR::Packer and Windows. IPC::Run doesn't
use List::AllUtils qw( first firstval );
use Biber::Constants;
use Biber::LaTeX::Recode;
use Biber::Entry::Name;
use Regexp::Common qw( balanced );
use Log::Log4perl qw(:no_extra_logdie_message);
use String::Interpolate;
my $logger = Log::Log4perl::get_logger('main');

=encoding utf-8

=head1 NAME

Biber::Utils - Various utility subs used in Biber

=cut

=head1 EXPORT

All functions are exported by default.

=cut

our @EXPORT = qw{ locate_biber_file driver_config makenamesid makenameid stringify_hash
  normalise_string normalise_string_hash normalise_string_underscore normalise_string_sort
  reduce_array remove_outer add_outer ucinit strip_nosort
  is_def is_undef is_def_and_notnull is_def_and_null
  is_undef_or_null is_notnull is_null normalise_utf8 inits join_name latex_recode_output
  filter_entry_options biber_error biber_warn ireplace is_user_entrytype_map is_user_field_map };

=head1 FUNCTIONS

=head2 driver_config

  Returns an XML::LibXML::Simple object for an input driver config file

=cut

sub driver_config {
  my $driver_name = shift;
  # we assume that the driver config file is in the same dir as the driver:
  (my $vol, my $driver_path, undef) = File::Spec->splitpath( $INC{"Biber/Input/file/${driver_name}.pm"} );

  # Deal with the strange world of Par::Packer paths, see similar code in Biber.pm
  my $dcf;
  if ($driver_path =~ m|/par\-| and $driver_path !~ m|/inc|) { # a mangled PAR @INC path
    $dcf = File::Spec->catpath($vol, "$driver_path/inc/lib/Biber/Input/file", "${driver_name}.dcf");
  }
  else {
    $dcf = File::Spec->catpath($vol, $driver_path, "${driver_name}.dcf");
  }

  # Read driver config file
  my $dcfxml = XML::LibXML::Simple::XMLin($dcf,
                                          'ForceContent' => 1,
                                          'ForceArray' => [ qr/\Afield\z/,
                                                            qr/\Aalias\z/,
                                                            qr/\Aalsoset\z/],
                                          'NsStrip' => 1);

  return $dcfxml;
}


=head2 locate_biber_file

  Searches for a file by

  For the exact path if the filename is absolute
  In the output_directory, if defined
  Relative to the current directory
  In the same directory as the control file
  Using kpsewhich, if available

=cut

sub locate_biber_file {
  my $filename = shift;
  my $filenamepath = $filename; # default if nothing else below applies
  my $outfile;
  # If output_directory is set, perhaps the file can be found there so
  # construct a path to test later
  if (my $outdir = Biber::Config->getoption('output_directory')) {
    $outfile = File::Spec->catfile($outdir, $filename);
  }

  # Filename is absolute
  if (File::Spec->file_name_is_absolute($filename) and -e $filename) {
    return $filename;
  }

  # File is output_directory
  if (defined($outfile) and -e $outfile) {
    return $outfile;
  }

  # File is relative to cwd
  if (-e $filename) {
    return $filename;
  }

  # File is where control file lives
  if (my $cfp = Biber::Config->get_ctrlfile_path) {
    my ($ctlvolume, $ctldir, undef) = File::Spec->splitpath($cfp);
    if ($ctlvolume) { # add vol sep for windows if volume is set and there isn't one
      $ctlvolume .= ':' unless $ctlvolume =~ /:\z/;
    }
    if ($ctldir) { # add path sep if there isn't one
      $ctldir .= '/' unless $ctldir =~ /\/\z/;
    }

    my $path = "$ctlvolume$ctldir$filename";

    return $path if -e $path;
  }

  # File is in kpse path
  if (can_run('kpsewhich')) {
    $logger->debug("Looking for file '$filename' via kpsewhich");
    my $found;
    my $err;
    run3  [ 'kpsewhich', $filename ], \undef, \$found, \$err, { return_if_system_error => 1};
    if ($?) {
      $logger->debug("kpsewhich returned error: $err ($!)");
    }
    $logger->trace("kpsewhich returned '$found'");
    if ($found) {
      $logger->debug("Found '$filename' via kpsewhich");
      chomp $found;
      $found =~ s/\cM\z//xms; # kpsewhich in cygwin sometimes returns ^M at the end
      # filename can be UTF-8 and run3() isn't clever with UTF-8
      return decode_utf8($found);
    }
    else {
      $logger->debug("Could not find '$filename' via kpsewhich");
    }
  }
  return undef;
}

=head2 biber_warn

    Wrapper around various warnings bits and pieces
    Logs a warning, add warning to the list of .bbl warnings and optionally
    increments warning count in Biber object, if present

=cut

sub biber_warn {
  my ($warning, $entry) = @_;
  $logger->warn($warning);
  $entry->add_warning($warning) if $entry;
  $Biber::MASTER->{warnings}++;
  return;
}


=head2 biber_error

    Wrapper around error logging
    Forces an exit.

=cut

sub biber_error {
  my $error = shift;
  $logger->error($error);
  $Biber::MASTER->{errors}++;
  # exit unless user requested not to for errors
  unless (Biber::Config->getoption('nodieonerror')) {
    $Biber::MASTER->display_problems;
    exit EXIT_ERROR;
  }
}

=head2 makenamesid

Given a Biber::Names object, return an underscore normalised
concatenation of all of the full name strings.

=cut

sub makenamesid {
  my $names = shift;
  my @namestrings;
  foreach my $name (@{$names->names}) {
    push @namestrings, $name->get_namestring;
  }
  my $tmp = join ' ', @namestrings;
  return normalise_string_underscore($tmp);
}

=head2 makenameid

Given a Biber::Name object, return an underscore normalised
concatenation of the full name strings.

=cut

sub makenameid {
  my $name = shift;
  return normalise_string_underscore($name->get_namestring);
}


=head2 latex_recode_output

  Tries to convert UTF-8 to TeX macros in passed string

=cut

sub latex_recode_output {
  my $string = shift;
  return Biber::LaTeX::Recode::latex_encode($string);
};

=head2 strip_nosort

Removes elements which are not to be used in sorting a name from a string

=cut

sub strip_nosort {
  my $string = shift;
  my $fieldname = shift;
  return '' unless $string; # Sanitise missing data
  return $string unless my $nosort = Biber::Config->getoption('nosort');
  # Strip user-defined REs from string
  my $restrings;
  foreach my $nsopt (@$nosort) {
    # Specific fieldnames override types
    if (lc($nsopt->{name}) eq lc($fieldname)) {
      push @$restrings, $nsopt->{value};
    }
  }

  unless ($restrings) {
    foreach my $nsopt (@$nosort) {
      next unless $nsopt->{name} =~ /\Atype_/xms;
      if ($NOSORT_TYPES{lc($nsopt->{name})}{lc($fieldname)}) {
        push @$restrings, $nsopt->{value};
      }
    }
  }
  # If no nosort to do, just return string
  return $string unless $restrings;
  foreach my $re (@$restrings) {
    $re = qr/$re/;
    $string =~ s/$re//gxms;
  }
  return $string;
}

=head2 normalise_string_sort

Removes LaTeX macros, and all punctuation, symbols, separators and control characters,
as well as leading and trailing whitespace for sorting strings.
It also decodes LaTeX character macros into Unicode as this is always safe when
normalising strings for sorting since they don't appear in the output.

=cut

sub normalise_string_sort {
  my $str = shift;
  my $fieldname = shift;
  return '' unless $str; # Sanitise missing data
  # First strip nosort REs
  $str = strip_nosort($str, $fieldname);
  # First replace ties with spaces or they will be lost
  $str =~ s/([^\\])~/$1 /g; # Foo~Bar -> Foo Bar
  # Replace LaTeX chars by Unicode for sorting
  # Don't bother if output is UTF-8 as in this case, we've already decoded everthing
  # before we read the file (see Biber.pm)
  unless (Biber::Config->getoption('bblencoding') eq 'UTF-8') {
    $str = latex_decode($str, strip_outer_braces => 1,
                              scheme => Biber::Config->getoption('decodecharsset'));
  }
  return normalise_string_common($str);
}

=head2 normalise_string

Removes LaTeX macros, and all punctuation, symbols, separators and control characters,
as well as leading and trailing whitespace for sorting strings.
Only decodes LaTeX character macros into Unicode if output is UTF-8

=cut

sub normalise_string {
  my $str = shift;
  return '' unless $str; # Sanitise missing data
  # First replace ties with spaces or they will be lost
  $str =~ s/([^\\])~/$1 /g; # Foo~Bar -> Foo Bar
  if (Biber::Config->getoption('bblencoding') eq 'UTF-8') {
    $str = latex_decode($str, strip_outer_braces => 1,
                              scheme => Biber::Config->getoption('decodecharsset'));
  }
  return normalise_string_common($str);
}

=head2 normalise_string_common

  Common bit for normalisation

=cut

sub normalise_string_common {
  my $str = shift;
  $str =~ s/\\[A-Za-z]+//g;        # remove latex macros (assuming they have only ASCII letters)
  $str =~ s/[\p{P}\p{S}\p{C}]+//g; # remove punctuation, symbols, separator and control
  $str =~ s/^\s+//;                # Remove leading spaces
  $str =~ s/\s+$//;                # Remove trailing spaces
  $str =~ s/\s+/ /g;               # collapse spaces
  return $str;
}

=head2 normalise_string_hash

  Normalise strings used for hashes. We collapse LaTeX macros into a vestige
  so that hashes are unique between things like:

  Smith
  {\v S}mith

  we replace macros like this to preserve their vestiges:

  \v S -> v:
  \" -> 34:

=cut

sub normalise_string_hash {
  my $str = shift;
  return '' unless $str; # Sanitise missing data
  $str =~ s/\\(\p{L}+)\s*/$1:/g; # remove tex macros
  $str =~ s/\\([^\p{L}])\s*/ord($1).':'/ge; # remove accent macros like \"a
  $str =~ s/[{}~\.\s]+//g; # Remove brackes, ties, dots, spaces
  return $str;
}

=head2 normalise_string_underscore

Like normalise_string, but also substitutes ~ and whitespace with underscore.

=cut

sub normalise_string_underscore {
  my $str = shift;
  return '' unless $str; # Sanitise missing data
  $str =~ s/([^\\])~/$1 /g; # Foo~Bar -> Foo Bar
  $str = normalise_string($str);
  $str =~ s/\s+/_/g;
  return $str;
}

=head2 reduce_array

reduce_array(\@a, \@b) returns all elements in @a that are not in @b

=cut

sub reduce_array {
  my ($a, $b) = @_;
  my %countb = ();
  foreach my $elem (@$b) {
    $countb{$elem}++;
  }
  my @result;
  foreach my $elem (@$a) {
    push @result, $elem unless $countb{$elem};
  }
  return @result;
}

=head2 remove_outer

    Remove surrounding curly brackets:
        '{string}' -> 'string'

=cut

sub remove_outer {
  my $str = shift;
  $str =~ s/^{(.+)}$/$1/;
  return $str;
}

=head2 add_outer

    Add surrounding curly brackets:
        'string' -> '{string}'

=cut

sub add_outer {
  my $str = shift;
  return '{' . $str . '}';
}


=head2 ucinit

    upper case of initial letters in a string

=cut

sub ucinit {
  my $str = shift;
  $str = lc($str);
  $str =~ s/\b(\p{Ll})/\u$1/g;
  return $str;
}

=head2 is_undef

    Checks for undefness of arbitrary things, including
    composite method chain calls which don't reliably work
    with defined() (see perldoc for defined())
    This works because we are just testing the value passed
    to this sub. So, for example, this is randomly unreliable
    even if the resulting value of the arg to defined() is "undef":

    defined($thing->method($arg)->method)

    wheras:

    is_undef($thing->method($arg)->method)

    works since we only test the return value of all the methods
    with defined()

=cut

sub is_undef {
  my $val = shift;
  return defined($val) ? 0 : 1;
}

=head2 is_def

    Checks for definedness in the same way as is_undef()

=cut

sub is_def {
  my $val = shift;
  return defined($val) ? 1 : 0;
}

=head2 is_undef_or_null

    Checks for undef or nullness (see is_undef() above)

=cut

sub is_undef_or_null {
  my $val = shift;
  return 1 if is_undef($val);
  return $val ? 0 : 1;
}

=head2 is_def_and_notnull

    Checks for def and unnullness (see is_undef() above)

=cut

sub is_def_and_notnull {
  my $arg = shift;
  if (defined($arg) and is_notnull($arg)) {
    return 1;
  }
  else {
    return 0;
  }
}

=head2 is_def_and_null

    Checks for def and nullness (see is_undef() above)

=cut

sub is_def_and_null {
  my $arg = shift;
  if (defined($arg) and is_null($arg)) {
    return 1;
  }
  else {
    return 0;
  }
}

=head2 is_null

    Checks for nullness

=cut

sub is_null {
  my $arg = shift;
  return is_notnull($arg) ? 0 : 1;
}

=head2 is_notnull

    Checks for notnullness

=cut

sub is_notnull {
  my $arg = shift;
  return undef unless defined($arg);
  my $st = is_notnull_scalar($arg);
  if (defined($st) and $st) { return 1; }
  my $at = is_notnull_array($arg);
  if (defined($at) and $at) { return 1; }
  my $ht = is_notnull_hash($arg);
  if (defined($ht) and $ht) { return 1; }
  my $ot = is_notnull_object($arg);
  if (defined($ot) and $ot) { return 1; }
  return 0;
}

=head2 is_notnull_scalar

    Checks for notnullness of a scalar

=cut

sub is_notnull_scalar {
  my $arg = shift;
  unless (ref \$arg eq 'SCALAR') {
    return undef;
  }
  return $arg ne '' ? 1 : 0;
}

=head2 is_notnull_array

    Checks for notnullness of an array (passed by ref)

=cut

sub is_notnull_array {
  my $arg = shift;
  unless (ref $arg eq 'ARRAY') {
    return undef;
  }
  my @arr = @$arg;
  return $#arr > -1 ? 1 : 0;
}

=head2 is_notnull_hash

    Checks for notnullness of an hash (passed by ref)

=cut

sub is_notnull_hash {
  my $arg = shift;
  unless (ref $arg eq 'HASH') {
    return undef;
  }
  my @arr = keys %$arg;
  return $#arr > -1 ? 1 : 0;
}

=head2 is_notnull_object

    Checks for notnullness of an object (passed by ref)

=cut

sub is_notnull_object {
  my $arg = shift;
  unless (ref($arg) =~ m/\ABiber::/xms) {
    return undef;
  }
  return $arg->notnull ? 1 : 0;
}


=head2 stringify_hash

    Turns a hash into a string of keys and values

=cut

sub stringify_hash {
  my $hashref = shift;
  my $string;
  while (my ($k,$v) = each %{$hashref}) {
    $string .= "$k => $v, ";
  }
  # Take off the trailing comma and space
  chop $string;
  chop $string;
  return $string;
}

=head2 normalise_utf8

  Normalise any UTF-8 encoding string immediately to exactly what we want
  We want the strict perl utf8 "UTF-8"

=cut

sub normalise_utf8 {
  if (defined(Biber::Config->getoption('bibencoding')) and
      Biber::Config->getoption('bibencoding') =~ m/\Autf-?8\z/xmsi) {
    Biber::Config->setoption('bibencoding', 'UTF-8');
  }
  if (defined(Biber::Config->getoption('bblencoding')) and
      Biber::Config->getoption('bblencoding') =~ m/\Autf-?8\z/xmsi) {
    Biber::Config->setoption('bblencoding', 'UTF-8');
  }
}

=head2 inits

   We turn the initials into an array so we can be flexible with them later
   The tie here is used only so we know what to split on. We don't want to make
   any typesetting decisions in Biber, like what to use to join initials so on
   output to the .bbl, we only use BibLaTeX macros.

=cut

sub inits {
  my $istring = shift;
  return [ split(/(?<!\\)~/, $istring) ];
}


=head2 join_name

  Replace all join typsetting elements in a name part (space, ties) with BibLaTeX macros
  so that typesetting decisions are made in BibLaTeX, not hard-coded in biber

=cut

sub join_name {
  my $nstring = shift;
  $nstring =~ s/(?<!\\\S)\s+/\\bibnamedelimb /gxms; # Don't do spaces in char macros
  $nstring =~ s/(?<!\\)~/\\bibnamedelima /gxms; # Don't do '\~'
  # Special delim after name parts ending in period
  $nstring =~ s/(?<=\.)\\bibnamedelim[ab]/\\bibnamedelimi/gxms;
  return $nstring;
}

=head2 filter_entry_options

    Process any per_entry option transformations which are necessary

=cut

sub filter_entry_options {
  my $options = shift;
  return '' unless $options;
  my @entryoptions = split /\s*,\s*/, $options;
  my @return_options;
  foreach (@entryoptions) {
    m/^([^=]+)=?(.+)?$/;
    given ($CONFIG_BIBLATEX_PER_ENTRY_OPTIONS{lc($1)}{OUTPUT}) {
      when (not defined($_) or $_ == 1) {
        push @return_options, $1 . ($2 ? "=$2" : '') ;
      }
      when (ref($_) eq 'ARRAY') {
        foreach my $map (@$_) {
          push @return_options, "$map=$2";
        }
      }
    }
  }
  return join(',', @return_options);
}

=head2 ireplace

    Do a search/replace on pattern/replacement passed in as variables

=cut

sub ireplace {
  my ($value, $val_match, $val_replace) = @_;
  if ($val_match) {
    $val_match = qr/$val_match/;
    $val_replace = new String::Interpolate $val_replace;
    $value =~ s/$val_match/$val_replace/egxms;
    return $value;
  }
  else {
    return $value;
  }
}

=head2 is_user_entrytype_map

    Check in a data structure of user entrytype mappings if a particular
    entrytype matches any mapping rules. Returns the target entrytype
    datastructure if there is a match, false otherwise.

=cut

sub is_user_entrytype_map {
  my ($user_map, $entrytype, $source) = @_;
  # entrytype specific mappings take precedence
  my $to;
MAP:  foreach my $map (@{$user_map->{map}}) {
    next unless $map->{maptype} eq 'entrytype';
    # Check persource restrictions
    # Don't compare case insensitively - this might not be correct
    unless (not exists($map->{per_datasource}) or
            (exists($map->{per_datasource}) and first {$_->{content} eq $source} @{$map->{per_datasource}})) {
      next;
    }

    foreach my $pair (@{$map->{map_pair}}) {
      if (lc($pair->{map_source}) eq $entrytype) {
        $to->{map_target} = $pair->{map_target} if exists($pair->{map_target});
        $to->{bmap_overwrite} = $map->{bmap_overwrite} if exists($map->{bmap_overwrite});
        if (exists($map->{also_set})) {
          foreach my $as (@{$map->{also_set}}) {
            $to->{also_set}{$as->{map_field}} = get_map_val($as, 'map_value');
          }
        }
        last MAP;
      }
    }
    foreach my $pair (@{$map->{map_pair}}) {
      if ($pair->{map_source} eq '*') {
        $to->{map_target} = $pair->{map_target} if exists($pair->{map_target});
        $to->{bmap_overwrite} = $map->{bmap_overwrite} if exists($map->{bmap_overwrite});
        if (exists($map->{also_set})) {
          foreach my $as (@{$map->{also_set}}) {
            $to->{also_set}{$as->{map_field}} = get_map_val($as, 'map_value');
          }
        }
        last MAP;
      }
    }
  }

  return $to; # simple entrytype map with no per_datasource restriction
}

=head2 is_user_field_map

    Check in a data structure of user field mappings if a particular
    field matches any mapping rules. Returns the target field
    datastructure if there is a match, false otherwise.

=cut

sub is_user_field_map {
  my ($user_map, $entrytype, $field, $source) = @_;
  my $to;
MAP:  foreach my $map (@{$user_map->{map}}) {
    next unless $map->{maptype} eq 'field';

    # Check pertype restrictions
    unless (not exists($map->{per_type}) or
            (exists($map->{per_type}) and first {lc($_->{content}) eq $entrytype} @{$map->{per_type}})) {
      next;
    }

    # Check per_datasource restrictions
    # Don't compare case insensitively - this might not be correct
    unless (not exists($map->{per_datasource}) or
            (exists($map->{per_datasource}) and first {$_->{content} eq $source} @{$map->{per_datasource}})) {
      next;
    }

    foreach my $pair (@{$map->{map_pair}}) {
      if (lc($pair->{map_source}) eq $field) {
        if (my $v = get_map_val($pair, 'map_target')) {
          $to->{map_target} = $v
        }
        $to->{map_match}  = $pair->{map_match} if exists($pair->{map_match});
        $to->{map_replace}  = $pair->{map_replace} if exists($pair->{map_replace});
        $to->{bmap_overwrite} = $map->{bmap_overwrite} if exists($map->{bmap_overwrite});
        if (exists($map->{also_set})) {
          foreach my $as (@{$map->{also_set}}) {
            $to->{also_set}{$as->{map_field}} = get_map_val($as, 'map_value');
          }
        }
        last MAP;
      }
    }
  }
  return $to;
}

=head2 get_map_val

  Cosmetic to get data into an easy to consume format for drivers.
  Look for special target markers or use the default if none found.

=cut

sub get_map_val {
  my ($m, $def) = @_;
  my $v;
  given ($m) {
    when (exists($m->{bmap_null}) and $m->{bmap_null} == 1) {
      $v = 'bmap_null';
    }
    when (exists($m->{bmap_origfield}) and $m->{bmap_origfield} == 1) {
      $v = 'bmap_origfield';
    }
    when (exists($m->{bmap_origentrytype}) and $m->{bmap_origentrytype} == 1) {
      $v = 'bmap_origentrytype';
    }
    default {
      $v = $m->{$def};
    }
  }
  return $v;
}

1;

__END__

=head1 AUTHOR

François Charette, C<< <firmicus at gmx.net> >>
Philip Kime C<< <philip at kime.org.uk> >>

=head1 BUGS

Please report any bugs or feature requests on our sourceforge tracker at
L<https://sourceforge.net/tracker2/?func=browse&group_id=228270>.

=head1 COPYRIGHT & LICENSE

Copyright 2009-2011 François Charette and Philip Kime, all rights reserved.

This module is free software.  You can redistribute it and/or
modify it under the terms of the Artistic License 2.0.

This program is distributed in the hope that it will be useful,
but without any warranty; without even the implied warranty of
merchantability or fitness for a particular purpose.

=cut
