package Biber::Output::bblxml;
use v5.24;
use strict;
use warnings;
use parent qw(Biber::Output::base);

use Biber::Config;
use Biber::Constants;
use Biber::Entry;
use Biber::Utils;
use Encode;
use List::AllUtils qw( :all );
use IO::File;
use IO::String;
use Log::Log4perl qw( :no_extra_logdie_message );
use Scalar::Util qw(looks_like_number);
use XML::Writer;
use Unicode::Normalize;
my $logger = Log::Log4perl::get_logger('main');

=encoding utf-8

=head1 NAME

Biber::Output::bblxml - class for Biber output of .bbl in XML format

=cut

=head2 new

    Initialize a Biber::Output::bbxml object

=cut


sub new {
  my $class = shift;
  my $obj = shift;
  my $self;
  if (defined($obj) and ref($obj) eq 'HASH') {
    $self = bless $obj, $class;
  }
  else {
    $self = bless {}, $class;
  }

  return $self;
}



=head2 set_output_target_file

    Set the output target file of a Biber::Output::bblxml object
    A convenience around set_output_target so we can keep track of the
    filename

=cut

sub set_output_target_file {
  my ($self, $bblxmlfile, $init) = @_;

  # we assume that the schema files are in the same dir as Biber.pm:
  (my $vol, my $biber_path, undef) = File::Spec->splitpath( $INC{"Biber.pm"} );

  $self->{output_target_file} = $bblxmlfile;

  if ($init) {
    my $bblxml = 'https://sourceforge.net/projects/biblatex/bblxml';
    $self->{xml_prefix} = $bblxml;

    my $schemafile;
    my $exts = join('|', values %DS_EXTENSIONS);
    if ($bblxmlfile =~ m/\.(?:$exts)$/) {
      $schemafile = $bblxmlfile =~ s/\.(?:$exts)$/.rng/r;
    }
    else {
      # in tests, there is no extension as we are using a temp file
      $schemafile = $bblxmlfile . '.rng';
    }

    my $of;
    if ($bblxmlfile eq '-') {
      open($of, '>&:encoding(UTF-8)', STDOUT);
    }
    else {
      $of = IO::File->new($bblxmlfile, '>:encoding(UTF-8)');
    }
    $of->autoflush;             # Needed for running tests to string refs

    my $xml = XML::Writer->new(OUTPUT      => $of,
                               ENCODING   => 'UTF-8',
                               DATA_MODE   => 1,
                               DATA_INDENT => Biber::Config->getoption('output_indent'),
                               NAMESPACES  => 1,
                               UNSAFE      => 1,
                               PREFIX_MAP  => {$bblxml => 'bbl'});
    $xml->xmlDecl();
    $xml->pi('xml-model', "href=\"$schemafile\" type=\"application/xml\" schematypens=\"http://relaxng.org/ns/structure/1.0\"");
    $xml->comment("Auto-generated by Biber::Output::bblxml");

    $xml->startTag([$self->{xml_prefix}, 'refsections']);
    return $xml;
  }
  return;
}

=head2 set_output_entry

  Set the .bblxml output for an entry. This is the meat of
  the .bblxml output

=cut

sub set_output_entry {
  my $self = shift;
  my $be = shift; # Biber::Entry object
  my $bee = $be->get_field('entrytype');
  my $section = shift; # Section object the entry occurs in
  my $dm = shift; # Data Model object
  my $dmh = Biber::Config->get_dm_helpers;
  my $acc = '';
  my $secnum = $section->number;
  my $key = $be->get_field('citekey');
  my $xml_prefix = 'https://sourceforge.net/projects/biblatex/bblxml';
  my $un = Biber::Config->getblxoption($secnum, 'uniquename', $bee, $key);
  my $ul = Biber::Config->getblxoption($secnum, 'uniquelist', $bee, $key);
  my ($lni, $lnf, $lnl) = $be->get_labelname_info->@*;
  my $nl = $be->get_field($lni, $lnf, $lnl);

  # Per-namelist uniquelist
  if (defined($lni) and $nl->get_uniquelist) {
    $ul = $nl->get_uniquelist;
  }

  # Per-namelist uniquename
  if (defined($lni) and $nl->get_uniquename) {
    $un = $nl->get_uniquename;
  }

  my $xml = XML::Writer->new(OUTPUT      => 'self',
                             ENCODING    => 'UTF-8',
                             DATA_MODE   => 1,
                             DATA_INDENT => Biber::Config->getoption('output_indent'),
                             NAMESPACES  => 1,
                             PREFIX_MAP  => {$xml_prefix => 'bbl'});


  # Skip entrytypes we don't want to output according to datamodel
  return if $dm->entrytype_is_skipout($bee);

  my @entryopts;
  if (defined($be->get_field('crossrefsource'))) {
    push @entryopts, ('source', 'crossref');
  }

  if (defined($be->get_field('xrefsource'))) {
    push @entryopts, ('source', 'xref');
  }

  push @entryopts, ('singletitle'         => '[BDS]SINGLETITLE[/BDS]');
  push @entryopts, ('uniquetitle'         => '[BDS]UNIQUETITLE[/BDS]');
  push @entryopts, ('uniquebaretitle'     => '[BDS]UNIQUEBARETITLE[/BDS]');
  push @entryopts, ('uniquework'          => '[BDS]UNIQUEWORK[/BDS]');
  push @entryopts, ('uniqueprimaryauthor' => '[BDS]UNIQUEPRIMARYAUTHOR[/BDS]');

  $xml->startTag([$xml_prefix, 'entry'], key => _bblxml_norm($key), type => _bblxml_norm($bee), @entryopts);
  my @opts;
  foreach my $opt (filter_entry_options($secnum, $be)->@*) {
    push @opts, $opt;
  }
  if (@opts) {
    $xml->startTag([$xml_prefix, 'options']);
    foreach (@opts) {
      $xml->dataElement([$xml_prefix, 'option'], _bblxml_norm($_));
    }
    $xml->endTag();# options
  }

  # Generate set information
  # Set parents are special and need very little
  if ($bee eq 'set') {# Set parents get <set> entry ...

    $xml->dataElement('BDS', 'ENTRYSET');

    # Set parents need this - it is the labelalpha from the first entry
    if (Biber::Config->getblxoption(undef, 'labelalpha', $bee, $key)) {
      $xml->dataElement('BDS', 'LABELALPHA');
      $xml->dataElement('BDS', 'EXTRAALPHA');
    }

    $xml->dataElement('BDS', 'SORTINIT');
    $xml->dataElement('BDS', 'SORTINITHASH');

    # labelprefix is list-specific. It is only defined if there is no shorthand
    # (see biblatex documentation)
    $xml->dataElement('BDS', 'LABELPREFIX');

    # Label can be in set parents
    if (my $lab = $be->get_field('label')) {
      $xml->dataElement([$xml_prefix, 'field'], _bblxml_norm($lab), name => 'label');
    }

    # Annotation can be in set parents
    if (my $ann = $be->get_field('annotation')) {
      $xml->dataElement([$xml_prefix, 'field'], _bblxml_norm($ann), name => 'annotation');
    }

    # Skip everything else
    # labelnumber/labelprefix etc. are generated by biblatex after reading the .bbl
    goto ENDENTRY;

  }
  else { # Everything else that isn't a set parent ...
    if (my $es = $be->get_field('entryset')) { # ... gets a <inset> if it's a set member
      $xml->startTag([$xml_prefix, 'inset']);
      foreach my $m ($es->get_items->@*) {
        $xml->dataElement([$xml_prefix, 'member'], _bblxml_norm($m));
      }
      $xml->endTag();# inset
    }
  }

  # Output name fields
  foreach my $n ($dmh->{namelists}->@*) {
    next if $dm->field_is_skipout($n);
    foreach my $alts ($be->get_alternates_for_field($n)->@*) {
      my $nf = $alts->{val};
      my $form = $alts->{form};
      my $lang = $alts->{lang};
      my $nlid = $nf->get_id;

      my %plo;

      # Did we have "and others" in the data?
      if ( $nf->get_morenames ) {
        $plo{more} = 'true';
      }

      my $total = $nf->count;

      if (defined($lni) and $lni eq $n) {

        # Add uniquelist if requested
        # Don't use angles in attributes ...
        if ($ul ne 'false') {
          $plo{ul} = "[BDS]UL-${nlid}[/BDS]";
        }

        # Add per-namelist options
        foreach my $nlo (keys $CONFIG_SCOPEOPT_BIBLATEX{NAMELIST}->%*) {
          if (defined($nf->${\"get_$nlo"})) {
            my $nlov = $nf->${\"get_$nlo"};

            if ($CONFIG_BIBLATEX_OPTIONS{NAMELIST}{$nlo}{OUTPUT}) {
              $plo{$nlo} = map_boolean($nlo, $nlov, 'tostring');
            }
          }
        }
      }

      # Internally, no distinction is made between multiscript and
      # non-multiscript fields but it is on output
      my @ms = ();
      if ($dm->is_multiscript($n)) {
        push @ms, ('msform' => $form) if $form;
        push @ms, ('mslang' => $lang) if $lang;
      }

      $xml->startTag([$xml_prefix, 'names'], type => $n, @ms, count => $total, map {$_ => $plo{$_}} sort keys %plo);

      # Now the names
      for (my $i = 1; $i <= $total; $i++) {
        my $n = $nf->names->[$i-1];

        # Per-name uniquename if this is labelname
        if ($lni eq $n) {
          if (defined($n->get_uniquename)) {
            $un = $n->get_uniquename;
          }
        }

        $n->name_to_bblxml($xml, $xml_prefix, $nf, $un, $i);
      }
      $xml->endTag();           # names
    }
  }

  # Output list fields
  foreach my $listfield ($dm->get_fields_of_fieldtype('list')->@*) {
    next if $dm->field_is_datatype('name', $listfield); # name is a special list
    next if $dm->field_is_datatype('uri', $listfield); # special lists
    next if $dm->field_is_skipout($listfield);

    foreach my $alts ($be->get_alternates_for_field($listfield)->@*) {
      my $lf = $alts->{val};
      my $form = $alts->{form};
      my $lang = $alts->{lang};

      my %plo;

      if ( lc($lf->last_item) eq Biber::Config->getoption('others_string') ) {
        # Did we have "and others" in the data?
        $plo{more} = 'true';
        $lf->del_last_item;
      }

      # Internally, no distinction is made between multiscript and
      # non-multiscript fields but it is on output
      my @ms = ();
      if ($dm->is_multiscript($listfield)) {
        push @ms, ('msform' => $form) if $form;
        push @ms, ('mslang' => $lang) if $lang;
      }

      my $total = $lf->count;
      $xml->startTag([$xml_prefix, 'list'], name => $listfield, @ms, count => $total, map {$_ => $plo{$_}} sort keys %plo);
      foreach my $f ($lf->get_items->@*) {
        $xml->dataElement([$xml_prefix, 'item'], _bblxml_norm($f));
      }
      $xml->endTag();# list
    }
  }

  # Output labelname hashes
  $xml->dataElement('BDS', 'NAMEHASH');
  my $fullhash = $be->get_field('fullhash');
  $xml->dataElement([$xml_prefix, 'field'], _bblxml_norm($fullhash), name => 'fullhash') if $fullhash;
  $xml->dataElement('BDS', 'BIBNAMEHASH');

  # Output namelist hashes
  foreach my $n ($dmh->{namelists}->@*) {
    foreach my $alts ($be->get_alternates_for_field($n)->@*) {
      my $val = $alts->{val};
      my $form = $alts->{form};
      my $lang = $alts->{lang};

      $xml->dataElement('BDS', "${n}${form}${lang}NAMEHASH");
      if (my $fullhash = $be->get_field("${n}${form}${lang}fullhash")) {
        $xml->dataElement([$xml_prefix, 'field'], _bblxml_norm($fullhash), name => "${n}${form}${lang}fullhash");
      }
      $xml->dataElement('BDS', "${n}${form}${lang}BIBNAMEHASH");
    }
  }

  # Output extraname if there is a labelname
  if ($lni) {
    $xml->dataElement('BDS', 'EXTRANAME');
  }

  if ( Biber::Config->getblxoption(undef, 'labelalpha', $bee, $key) ) {
    $xml->dataElement('BDS', 'LABELALPHA');
  }

  $xml->dataElement('BDS', 'SORTINIT');
  $xml->dataElement('BDS', 'SORTINITHASH');

  # The labeldateparts option determines whether "extradate" is output
  if (Biber::Config->getblxoption(undef, 'labeldateparts', $bee, $key)) {
    $xml->dataElement('BDS', 'EXTRADATE');
    if (my $edscope = $be->get_field('extradatescope')) {
      $xml->dataElement([$xml_prefix, 'field'], _bblxml_norm($edscope), name => 'extradatescope');
    }
    if ($be->field_exists('labeldatesource')) {
      $xml->dataElement([$xml_prefix, 'field'], _bblxml_norm($be->get_field('labeldatesource')), name => 'labeldatesource');
    }
  }

  # labelprefix is list-specific. It is only defined if there is no shorthand
  # (see biblatex documentation)
  unless ($be->get_field('shorthand')) {
    $xml->dataElement('BDS', 'LABELPREFIX');
  }

  # The labeltitle option determines whether "extratitle" is output
  if (Biber::Config->getblxoption(undef, 'labeltitle', $bee, $key)) {
    $xml->dataElement('BDS', 'EXTRATITLE');
  }

  # The labeltitleyear option determines whether "extratitleyear" is output
  if (Biber::Config->getblxoption(undef, 'labeltitleyear', $bee, $key)) {
    $xml->dataElement('BDS', 'EXTRATITLEYEAR');
  }

  # The labelalpha option determines whether "extraalpha" is output
  if (Biber::Config->getblxoption(undef, 'labelalpha', $bee, $key)) {
    $xml->dataElement('BDS', 'EXTRAALPHA');
  }

  # The source field for labelname
  if ($lni) {
    $xml->dataElement([$xml_prefix, 'field'], _bblxml_norm($lni), name => 'labelnamesource', msform => $lnf, 'mslang' => $lnl);
  }

  # The source field for labeltitle
  if (my ($lti, $ltf, $ltl) = $be->get_labeltitle_info->@*) {
    $xml->dataElement([$xml_prefix, 'field'], _bblxml_norm($lti), name => 'labeltitlesource', 'msform' => $ltf, 'mslang' => $ltl);
  }

  if (my $ck = $be->get_field('clonesourcekey')) {
    $xml->dataElement([$xml_prefix, 'field'], _bblxml_norm($ck), name => 'clonesourcekey');
  }


  # Output fields
  foreach my $field (sort $dm->get_fields_of_type('field',
                                                  ['entrykey',
                                                   'key',
                                                   'integer',
                                                   'literal',
                                                   'code',
                                                   'verbatim'])->@*) {
    foreach my $alts ($be->get_alternates_for_field($field)->@*) {
      my $val = $alts->{val};
      my $form = $alts->{form};
      my $lang = $alts->{lang};

      if ( length($val) or     # length() catches '0' values, which we want
           ($dm->field_is_nullok($field) and
            $be->field_exists($field, $form, $lang))) {
        next if $dm->field_is_skipout($field);
        next if $dm->get_fieldformat($field) eq 'xsv';
        # we skip outputting the crossref or xref when the parent is not cited
        # (biblatex manual, section 2.2.3)
        # sets are a special case so always output crossref/xref for them since their
        # children will always be in the .bbl otherwise they make no sense.
        unless ($bee eq 'set') {
          next if ($field eq 'crossref' and
                   not $section->has_citekey($be->get_field('crossref')));
          next if ($field eq 'xref' and
                   not $section->has_citekey($be->get_field('xref')));
        }

        # Internally, no distinction is made between multiscript and
        # non-multiscript fields but it is on output
        my @ms = ();
        if ($dm->is_multiscript($field)) {
          push @ms, ('msform' => $form) if $form;
          push @ms, ('mslang' => $lang) if $lang;
        }

        $xml->dataElement([$xml_prefix, 'field'],
                          _bblxml_norm($val), name => $field, @ms);
      }
    }
  }

  # Date parts
  foreach my $field (sort $dm->get_fields_of_type('field', 'datepart')->@*) {
    my $val = $be->get_field($field);

    if ( length($val) or # length() catches '0' values, which we want
         ($dm->field_is_nullok($field) and
          $be->field_exists($field))) {
      my @attrs = ('name', $field);
      my $str;
      if (my ($d) = $field =~ m/^(.*)(?!end)year$/) {

        # Output absolute astronomical year by default (with year 0)
        # biblatex will adjust the years when printed with BCE/CE eras
        $val = abs($val) if looks_like_number($val);

        # Unspecified granularity
        if (my $unspec = $be->get_field("${d}dateunspecified")) {
            push @attrs, ('unspecified', $unspec);
        }

        # Julian dates
        if ($be->get_field("${d}datejulian")) {
          push @attrs, ('startjulian', 'true');
        }
        if ($be->get_field("${d}enddatejulian")) {
          push @attrs, ('endjulian', 'true');
        }

        # Circa dates
        if ($be->get_field("${d}dateapproximate")) {
          push @attrs, ('startcirca', 'true');
        }
        if ($be->get_field("${d}enddateapproximate")) {
          push @attrs, ('endcirca', 'true');
        }

        # Uncertain dates
        if ($be->get_field("${d}dateuncertain")) {
          push @attrs, ('startuncertain', 'true');
        }
        if ($be->get_field("${d}enddateuncertain")) {
          push @attrs, ('enduncertain', 'true');
        }

        # Unknown dates
        if ($be->get_field("${d}dateunknown")) {
          push @attrs, ('startunknown', 'true');
        }
        if ($be->get_field("${d}enddateunknown")) {
          push @attrs, ('endunknown', 'true');
        }

        # Only output era for date if:
        # The field is "year" and it came from splitting a date
        # The field is any other startyear
        if ($d eq '' and $be->get_field('datesplit')) {
          if (my $era = $be->get_field("${d}era")) {
            push @attrs, ('startera', $era);
          }
          if (my $era = $be->get_field("${d}endera")) {
            push @attrs, ('endera', $era);
          }
          $str = _bblxml_norm($be->get_field("${d}year"));
        }
        else {
          $str = _bblxml_norm($val);
        }
      }
      else {
        $str = _bblxml_norm($val);
      }
      $xml->dataElement([$xml_prefix, 'field'], $str, @attrs);
    }
  }

  # XSV fields
  foreach my $field ($dmh->{xsv}->@*) {
    next if $dm->field_is_skipout($field);
    # keywords is by default field/xsv/keyword but it is in fact
    # output with its own special macro below
    next if $field eq 'keywords';

    foreach my $alts ($be->get_alternates_for_field($field)->@*) {
      my $f = $alts->{val};
      my $form = $alts->{form};
      my $lang = $alts->{lang};

      # Internally, no distinction is made between multiscript and
      # non-multiscript fields but it is on output
      my @ms = ();
      if ($dm->is_multiscript($field)) {
        push @ms, ('msform' => $form) if $form;
        push @ms, ('mslang' => $lang) if $lang;
      }

      $xml->startTag([$xml_prefix, 'field'], name => $field, @ms, format => 'xsv');
      foreach my $f ($f->get_items->@*) {
        $xml->dataElement([$xml_prefix, 'item'], _bblxml_norm($f));
      }
      $xml->endTag();# field
    }
  }

  foreach my $rfield ($dmh->{ranges}->@*) {
    if ( my $rf = $be->get_field($rfield) ) {
      next if $dm->field_is_skipout($rfield);
      # range fields are an array ref of two-element array refs [range_start, range_end]
      # range_end can be be empty for open-ended range or undef
      my @pr;
      $xml->startTag([$xml_prefix, 'range'], name => $rfield);
      foreach my $f ($rf->@*) {
        $xml->startTag([$xml_prefix, 'item'], length => rangelen($rf));
        $xml->dataElement([$xml_prefix, 'start'], _bblxml_norm($f->[0]));
        if (defined($f->[1])) {
          $xml->dataElement([$xml_prefix, 'end'], _bblxml_norm($f->[1]));
        }
        $xml->endTag();# item
      }
      $xml->endTag();# range
    }
  }

  # uri fields
  foreach my $uri ($dmh->{uris}->@*) {
    if ( my $f = $be->get_field($uri) ) {
      next if $dm->field_is_skipout($uri);
      $xml->dataElement([$xml_prefix, 'field'], _bblxml_norm($f), name => $uri);
    }
  }

  # uri lists
  foreach my $uril ($dmh->{urils}->@*) {
    if ( my $urilf = $be->get_field($uril) ) {
      next if $dm->field_is_skipout($uril);
      my %plo;
      if ( lc($urilf->last_item) eq Biber::Config->getoption('others_string') ) {
        $plo{$uril} = 'true';
        $urilf->del_last_item; # remove the last element in the array
      }
      my $total = $urilf->count;
      $xml->startTag([$xml_prefix, 'list'], name => $uril, count => $total, map {$_ => $plo{$_}} sort keys %plo);

      foreach my $f ($urilf->get_items->@*) {
        $xml->dataElement([$xml_prefix, 'item'], _bblxml_norm($f));
      }
      $xml->endTag();# list
    }
  }

  # Keywords
  if ( my $kws = $be->get_field('keywords') ) {
    $xml->startTag([$xml_prefix, 'keywords']);
    foreach my $k ($kws->get_items->@*) {
      $xml->dataElement([$xml_prefix, 'keyword'], _bblxml_norm($k));
    }
    $xml->endTag();# keywords
  }


  # Output nocite boolean
  if ($be->get_field('nocite')) {
    $xml->emptyTag([$xml_prefix, 'nocite']);
  }

  # Output annotations
  foreach my $f (Biber::Annotation->get_annotated_fields('field', $key)) {
    foreach my $form (Biber::Annotation->get_annotation_forms($key, $f)) {
      foreach my $lang (Biber::Annotation->get_annotation_langs($key, $f, $form)) {
        foreach my $n (Biber::Annotation->get_annotations('field', $key, $f, $form, $lang)) {
          my $v = Biber::Annotation->get_annotation('field', $key, $f, $form, $lang, $n);
          $v = lc($v) if $n eq 'langtags'; # normalise langtags
          my $l = Biber::Annotation->is_literal_annotation('field', $key, $f, $form, $lang, $n);
          my @ms = ();
          if ($dm->is_multiscript($f)) {
            push @ms, ('msform' => $form) if $form;
            push @ms, ('mslang' => $lang) if $lang;
          }
          $xml->dataElement([$xml_prefix, 'annotation'],
                            scope => 'field',
                            field => _bblxml_norm($f),
                            @ms,
                            name  => bblxml_norm($n),
                            literal => $l,
                            value => _bblxml_norm($v)
                           );
        }
      }
    }
  }

  foreach my $f (Biber::Annotation->get_annotated_fields('item', $key)) {
    foreach my $form (Biber::Annotation->get_annotation_forms($key, $f)) {
      foreach my $lang (Biber::Annotation->get_annotation_langs($key, $f, $form)) {
        foreach my $n (Biber::Annotation->get_annotations('item', $key, $f, $form, $lang)) {
          foreach my $c (Biber::Annotation->get_annotated_items('item', $key, $f, $n, $form, $lang)) {
            my $v = Biber::Annotation->get_annotation('item', $key, $f, $form, $lang, $n, $c);
            $v = lc($v) if $n eq 'langtags'; # normalise langtags
            my $l = Biber::Annotation->is_literal_annotation('item', $key, $f, $form, $lang, $n, $c);
            my @ms = ();
            if ($dm->is_multiscript($f)) {
              push @ms, ('msform' => $form) if $form;
              push @ms, ('mslang' => $lang) if $lang;
            }
            $xml->dataElement([$xml_prefix, 'annotation'],
                              scope => 'item',
                              field => _bblxml_norm($f),
                              @ms,
                              name  => bblxml_norm($n),
                              literal => $l,
                              item  => _bblxml_norm($c),
                              value => _bblxml_norm($v)
                             );
          }
        }
      }
    }
  }

  foreach my $f (Biber::Annotation->get_annotated_fields('part', $key)) {
    foreach my $form (Biber::Annotation->get_annotation_forms($key, $f)) {
      foreach my $lang (Biber::Annotation->get_annotation_langs($key, $f, $form)) {
        foreach my $n (Biber::Annotation->get_annotations('part', $key, $f, $form, $lang)) {
          foreach my $c (Biber::Annotation->get_annotated_items('part', $key, $f, $n, $form, $lang)) {
            foreach my $p (Biber::Annotation->get_annotated_parts('part', $key, $f, $n, $c, $form, $lang)) {
              my $v = Biber::Annotation->get_annotation('part', $key, $f, $form, $lang, $n, $c, $p);
              $v = lc($v) if $n eq 'langtags'; # normalise langtags
              my $l = Biber::Annotation->is_literal_annotation('part', $key, $f, $form, $lang, $n, $c, $p);
              my @ms = ();
              if ($dm->is_multiscript($f)) {
                push @ms, ('msform' => $form) if $form;
                push @ms, ('mslang' => $lang) if $lang;
              }
              $xml->dataElement([$xml_prefix, 'annotation'],
                                scope => 'part',
                                field => _bblxml_norm($f),
                                @ms,
                                name  => bblxml_norm($n),
                                literal => $l,
                                item  => _bblxml_norm($c),
                                part  => _bblxml_norm($p),
                                value => _bblxml_norm($v)
                               );
            }
          }
        }
      }
    }
  }

  # Append any warnings to the entry, if any
  if (my $w = $be->get_warnings) {
    foreach my $warning ($w->@*) {
      $xml->dataElement([$xml_prefix, 'warning'], _bblxml_norm($warning));
    }
  }

 ENDENTRY:
  $xml->endTag();# entry

  # Create an index by keyname for easy retrieval
  my $exml = $xml->end();
  # Remove NS decl as we will have this at the top level
  # This exists as we are making a new XML writer for each entry
  # which makes sense because the entries are not generated in the context
  # of the main XML due to instantiate_entry() requirements
  $exml =~ s/\sxmlns:bbl="$xml_prefix"//xms;
  $self->{output_data}{ENTRIES}{$secnum}{index}{$key} = \$exml;

  return;
}


=head2 output

    BBL output method - this takes care to output entries in the explicit order
    derived from the virtual order of the citekeys after sortkey sorting.

=cut

sub output {
  my $self = shift;
  my $data = $self->{output_data};
  my $dm = Biber::Config->get_dm;
  my $xml = $self->{output_target};
  my $xml_prefix = $self->{xml_prefix};
  my $target_string = "Target"; # Default
  if ($self->{output_target_file}) {
    $target_string = $self->{output_target_file};
  }

  if ($logger->is_debug()) {# performance tune
    $logger->debug('Preparing final output using class ' . __PACKAGE__ . '...');
  }

  $logger->info("Writing '$target_string' with encoding '" . Biber::Config->getoption('output_encoding') . "'");
  $logger->info('Converting UTF-8 to TeX macros on output to .bbl') if Biber::Config->getoption('output_safechars');

  foreach my $secnum (sort keys $data->{ENTRIES}->%*) {
    if ($logger->is_debug()) {# performance tune
      $logger->debug("Writing entries for section $secnum");
    }

    $xml->startTag([$xml_prefix, 'refsection'], id => $secnum);

    my $section = $self->get_output_section($secnum);

    my @lists; # Need to reshuffle list to put global sort order list at end, see below

    # This sort is cosmetic, just to order the lists in a predictable way in the .bbl
    # but omit the global context list so that we can add this last
    foreach my $list (sort {$a->get_sortingtemplatename cmp $b->get_sortingtemplatename} $Biber::MASTER->datalists->get_lists_for_section($secnum)->@*) {
      if ($list->get_sortingtemplatename eq Biber::Config->getblxoption(undef, 'sortingtemplatename') and
          $list->get_sortingnamekeytemplatename eq 'global' and
          $list->get_labelprefix eq '' and
          $list->get_type eq 'entry') {
        next;
      }
      push @lists, $list;
    }

    # biblatex requires the last list in the .bbl to be the global sort  list
    # due to its sequential reading of the .bbl as the final list overrides the
    # previously read ones and the global list determines the order of labelnumber
    # and sortcites etc. when not using defernumbers
    push @lists, $Biber::MASTER->datalists->get_lists_by_attrs(section => $secnum,
                                                               type    => 'entry',
                                                               sortingtemplatename => Biber::Config->getblxoption(undef, 'sortingtemplatename'))->@*;

    foreach my $list (@lists) {
      next unless $list->count_keys; # skip empty lists
      my $listssn = $list->get_sortingtemplatename;
      my $listsnksn = $list->get_sortingnamekeytemplatename;
      my $listpn = $list->get_labelprefix;
      my $listtype = $list->get_type;
      my $listname = $list->get_name;

      if ($logger->is_debug()) {# performance tune
        $logger->debug("Writing entries in '$listname' list of type '$listtype' with sortingtemplatename '$listssn', sort name key scheme '$listsnksn' and labelprefix '$listpn'");
      }

      $xml->startTag([$xml_prefix, 'datalist'], type => $listtype, id => $listname);
      $xml->raw("\n");

      # The order of this array is the sorted order
      foreach my $k ($list->get_keys->@*) {
        if ($logger->is_debug()) {# performance tune
          $logger->debug("Writing entry for key '$k'");
        }

        my $entry = $data->{ENTRIES}{$secnum}{index}{$k};

        # Instantiate any dynamic, list specific entry information
        my $entry_string = $list->instantiate_entry($section, $entry, $k, 'bblxml');

        # If requested, add a printable sorting key to the output - useful for debugging
        if (Biber::Config->getoption('sortdebug')) {
          $entry_string = "      <!-- sorting key for '$k':\n           " . $list->get_sortdata_for_key($k)->[0] . " -->\n" . $entry_string;
        }

        # Now output
        # this requires UNSAFE set on the main xml writer object but
        # this is ok as the ->raw() call only adds XML written by another writer
        # which had UNSAFE=0
        $entry_string =~ s/^/      /gxms; # entries are separate docs so indent is wrong
        $xml->raw($entry_string);
      }
      $xml->raw('    ');
      $xml->endTag();    # datalist
    }

    # alias citekeys are global to a section
    foreach my $k ($section->get_citekey_aliases) {
      my $realkey = $section->get_citekey_alias($k);
      $xml->dataElement([$xml_prefix, 'keyalias'], _bblxml_norm($k), key => $realkey);
    }

    # undef citekeys are global to a section
    # Missing citekeys
    foreach my $k ($section->get_undef_citekeys) {
      $xml->dataElement([$xml_prefix, 'missing'], _bblxml_norm($k));
    }

    $xml->endTag();    # refsection
  }
  foreach my $tag (split(/,/, Biber::Config->get_langs)) {
    $xml->emptyTag([$xml_prefix, 'msmaplang'], 'langtag' => $tag, 'lang' => $LOCALE_MAP_R{lc($tag)});
  }
  $xml->dataElement([$xml_prefix, 'msforms'], Biber::Config->get_forms);
  $xml->dataElement([$xml_prefix, 'mslangs'], Biber::Config->get_langs);

  $xml->endTag();    # refsections

  $logger->info("Output to $target_string");
  $xml->end();


  my $schemafile;
  my $exts = join('|', values %DS_EXTENSIONS);
  if ($target_string =~ m/\.(?:$exts)$/) {
    $schemafile = $target_string =~ s/\.(?:$exts)$/.rng/r;
  }
  else {
    # in tests, there is no extension as we are using a temp file
    $schemafile = $target_string . '.rng';
  }

  # Generate schema to accompany output
  unless (Biber::Config->getoption('no_bblxml_schema')) {
    $dm->generate_bblxml_schema($schemafile);
  }

  if (Biber::Config->getoption('validate_bblxml')) {
    validate_biber_xml($target_string, 'bbl', 'https://sourceforge.net/projects/biblatex/bblxml', $schemafile);
  }

  return;
}

=head2 create_output_section

    Create the output from the sections data and push it into the
    output object.

=cut

sub create_output_section {
  my $self = shift;
  my $secnum = $Biber::MASTER->get_current_section;
  my $section = $Biber::MASTER->sections->get_section($secnum);

  # We rely on the order of this array for the order of the .bbl
  foreach my $k ($section->get_citekeys) {
    # Regular entry
    my $be = $section->bibentry($k) or biber_error("Cannot find entry with key '$k' to output");
    $self->set_output_entry($be, $section, Biber::Config->get_dm);
  }

  # Make sure the output object knows about the output section
  $self->set_output_section($secnum, $section);

  return;
}

sub _bblxml_norm {
  return NFC(normalise_string_bblxml(shift));
}
1;

__END__

=head1 AUTHORS

Philip Kime C<< <philip at kime.org.uk> >>

=head1 BUGS

Please report any bugs or feature requests on our Github tracker at
L<https://github.com/plk/biber/issues>.

=head1 COPYRIGHT & LICENSE

Copyright 2012-2020 Philip Kime, all rights reserved.

This module is free software.  You can redistribute it and/or
modify it under the terms of the Artistic License 2.0.

This program is distributed in the hope that it will be useful,
but without any warranty; without even the implied warranty of
merchantability or fitness for a particular purpose.

=cut
