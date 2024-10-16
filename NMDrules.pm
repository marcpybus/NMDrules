
=head1 NAME

NMDrules: A VEP plugin to predict NMD in stop codon generating variants

=head1 SYNOPSIS
 
mv NMDrules.pm  ~/.vep/Plugins
./vep -i variations.vcf --plugin NMDrules

=head1 DESCRIPTION 

#### Motivation

 - NMD prediction is becoming increasingly important for understanding the actual molecular mechanism driving gene-disease association.  
 - Protein truncating variants (PTVs) that escape NMD can exert their pathogenic effects through gain-of-function or dominant-negative mechanisms. Unfortunately, they are often confused with loss-of-function variants, which can lead to incorrect genetic diagnosis.  
 - After noticing the shortcomings* in predicting NMD escape variants of open-source variant annotators (e.g. VEP NMD plugin, SnpEff, LOFTEE) or the complex integration of specialised software (i. aenmd, NMDEscPredictor, NMDetective, ALoFT, nmd-escape) into VEP based annotation pipelines, I decided to implement a simple VEP plugin myself that performs NMD prediction of stop codon generating variants (i.e. stop_gained, stop_loss, some frameshift variants).  
 - In addition to applying the current canonical and non-canonical rules for NMD prediction, the plugin extracts information about the genomic context surrounding the generated stop codon, and leverages an hypothetical translation reinitiation.  

 \* The biggest shortcoming I've found is the inability to correctly infer the location of the stop codon generated by a frameshift variant. For example, variant EVL(NM_016337.3):c.573_574del:p.Val192ProfsTer105 generates a stop codon 315 bps downstream of the dinucleotide deletion. As implemented, most of the annotators mentioned above would consider the affected exon to be the same one where the deletion occurs, when in fact the stop codon is generated a couple of exons downstream.  

#### Description

This is a plugin for Ensembl Variant Effect Predictor (VEP) software that predicts whether a stop codon generating variant (i.e. stop_gained, stop_loss, some frameshift variants) triggers nonsense-mediated mRNA decay (`putative_NMD_triggering`) or not (`canonical_NMD_escaping`, `noncanonical_NMD_escaping`) based on the following rules (1) (`NMD_prediction => NMD_rule`):

* The variant is located in an intronless transcript: `canonical_NMD_escaping => intronless`  
* The variant is located in the last exon: `canonical_NMD_escaping => last_exon`  
* The variant is located in the last 50 bp of the penultimate exon: `canonical_NMD_escaping => 50bp_penult_exon`  
* The variant is located in the first 150 coding bases: `noncanonical_NMD_escaping => first_150bp`  
* The variant is located in an exon larger than 407 bp: `noncanonical_NMD_escaping => lt_407bp_exon`  

Then, it calculates the distance in bps to the next ATG (start codon) after the stop codon to leverage an hypothetical translation reinitiation (3) (`Next_ATG`). If no ATG is found downstream of the stop codon, the output value is -1. 

The plugin also shows the 2 codons/amino acids before the novel stop codon, plus the next nucleotide, for a detailed analysis, as they may influence the NMD efficiency (2) (`Stop_context`).  
Format: `-2codon(-2aa)-1codon(-1aa)stop_codon(Stop)fourth_letter`  

#### Example: 

Variant: 10-102509528-C-CG (GRCh37)  
HGVS: PAX2(NM_000278.5):c.76dup:p.Val26GlyfsTer28  
Annotation: `noncanonical_NMD_escaping|first_150bp|169|GCC(Ala)CTG(Leu)TGA(Stop)C`  

#### Implementation

The plugin starts by filtering in all variants with a stop codon (Ter) in their HGVSp notation. Exceptions are synonymous variants at the stop codon (e.g. p.Ter811=) or when no stop codon is inferred downstream of a frameshift variant (e.g. p.Ter257GlufsTer?). It then internally applies the mutation to the original cDNA to determine the location of the new stop codon. All insertions and deletions must be contained within the cDNA sequence.  

Splicing variants and deletions involving intron/exon boundaries are not considered because VEP cannot properly infer the mutated protein.  

This plugin has been tested on all the [gnomAD 2.1.1 exomes](https://storage.googleapis.com/gcp-public-data--gnomad/release/2.1.1/vcf/exomes/gnomad.exomes.r2.1.1.sites.vcf.bgz) variants without throwing any errors. Be aware that more complex variants may cause unobserved bugs.  

#### References

1. The impact of nonsense-mediated mRNA decay on genetic disease, gene editing and cancer immunotherapy (Lindeboom *et al.* 2019, Nature Genetics)  
2. Systematic analysis of nonsense variants uncovers peptide release rate as a novel modifier of nonsense-mediated mRNA decay efficiency (Kolokada *et al.* 2024, bioRxiv)  
3. Advanced variant classification framework reduces the false positive rate of predicted loss-of-function variants in population sequencing data (Singer-Berk *et al.* 2023, Am J Hum Genet)  

=head1 AUTHOR

Marc Pybus - L<https://github.com/marcpybus/>

=cut 

package NMDrules;

use strict;
use warnings;

use base  qw(Bio::EnsEMBL::Variation::Utils::BaseVepPlugin);

our $DEBUG = 0;

sub get_header_info {
  return {
    NMD_prediction => '"NMD prediction (putative_NMD_triggering, canonical_NMD_escaping, noncanonical_NMD_escaping)"',
    NMD_rule => '"NMD escaping rule (intronless, last_exon, 50bp_penult_exon, first_150bp, lt_407bp_exon)"',
    Next_ATG => '"Distance to the next ATG in base pairs (no ATG found is -1)"',
    Stop_context => '"Genomic context arround stop gained codon: -2codon(-2aa)-1codon(-1aa)stop_codon(Stop)fourth_letter"'
  }
}

sub run {
  my $self = shift; 
  my $tva = shift;

  my $tr = $tva->transcript;
  my $tv = $tva->transcript_variation;

  my $hgvsp = $tva->hgvs_protein;

  return {} unless defined($hgvsp) and $hgvsp =~ /Ter/ and $hgvsp !~ /\?/ and $hgvsp !~ /=/;
  # check if the variant has defined CDS & cDNA start & end positions
  if (!defined ($tv->cds_end) || !defined ($tv->cds_start) || !defined ($tv->cdna_end) || !defined ($tv->cdna_start)){
    return {};
  }

  if( $DEBUG == 1 ){
    my $hgvsg = $tva->hgvs_genomic;
    my $hgvsc = $tva->hgvs_transcript;
    print "\n$hgvsg $hgvsc $hgvsp\n";
  }

  my %aa_conversion = (
    'A' => 'Ala', 'R' => 'Arg', 'N' => 'Asn', 'D' => 'Asp', 'C' => 'Cys',
    'E' => 'Glu', 'Q' => 'Gln', 'G' => 'Gly', 'H' => 'His', 'I' => 'Ile',
    'L' => 'Leu', 'K' => 'Lys', 'M' => 'Met', 'F' => 'Phe', 'P' => 'Pro',
    'S' => 'Ser', 'T' => 'Thr', 'W' => 'Trp', 'Y' => 'Tyr', 'V' => 'Val',
    '*' => 'Stop'  # Stop codon
);

  my $stop_gained_offset = 0;

  my $check_last = 0;
  my $check_50bp_second_last = 0;
  my $check_407bp = 0;
  my $check_150bp = 0;
  my $check_no_introns = 0;

  my $output_hash = {};

  # variant feature location
  my $start_coding_cdna_location = $tr->cdna_coding_start;

  # fetch exons
  my @exons = @{ $tr->get_all_Exons }; 

  # load codon table
  my $codon_table;
  if(defined($tr->{_variation_effect_feature_cache})) {
      $codon_table = $tr->{_variation_effect_feature_cache}->{codon_table} || 1;
  }
  else {
      my ($attrib) = @{$tr->slice->get_all_Attributes('codon_table')};
      $codon_table = $attrib ? $attrib->value || 1 : 1;
  }

  # get cds sequence
  my $cds_seq = defined($tr->{_variation_effect_feature_cache})
            ? $tr->{_variation_effect_feature_cache}->{translateable_seq}
            : $tr->translateable_seq;
  my ($start, $end) = ($tv->cds_start, $tv->cds_end);

  # get 3' UTR sequence
  my $three_prime_utr = $tr->three_prime_utr ? $tr->three_prime_utr->seq() : '';

  # apply mutation
  my $mutated_cds_seq = $cds_seq;
  substr($mutated_cds_seq, $start - 1, $end - $start + 1) = $tva->seq_length > 0 ? $tva->feature_seq : '';

  my $mutated_cds_3_prime_utr_seq = $mutated_cds_seq . $three_prime_utr;

  # get mutated protein sequence
  my $codon_seq = Bio::Seq->new( -seq => $mutated_cds_3_prime_utr_seq, -moltype => 'dna', -alphabet => 'dna' );
  my $mutated_pep_raw = $codon_seq->translate(undef, undef, undef, $codon_table)->seq();

  print "mutated raw protein: $mutated_pep_raw\n" if $DEBUG == 1;

  # get stop codon position
  my $mutated_pep = $mutated_pep_raw;
  $mutated_pep =~ s/\*.*//;
  $mutated_pep = $mutated_pep . "*";
  my $stop_gained_position = 3 * length($mutated_pep);

  # get next ATG after stop_codon position
  my $next_atg_distance = -1;
  my $mutated_cds_seq_after_stop = "NoSeq";
  if( length($mutated_cds_3_prime_utr_seq) >= $stop_gained_position ){
    $mutated_cds_seq_after_stop = substr($mutated_cds_3_prime_utr_seq, $stop_gained_position);
    if( $mutated_cds_seq_after_stop =~ s/ATG.*// ){
      $mutated_cds_seq_after_stop = $mutated_cds_seq_after_stop . "ATG";
      $next_atg_distance = length($mutated_cds_seq_after_stop);
    }
  }

  print "stop cds pos: $stop_gained_position\n" if $DEBUG == 1;
  print "mutated cds+3'utr: $mutated_cds_seq\n" if $DEBUG == 1;
  print "mutated protein: $mutated_pep\n" if $DEBUG == 1;
  print "next ATG distance: $next_atg_distance\n" if $DEBUG == 1;
  print "mutated cds after stop to ATG: $mutated_cds_seq_after_stop\n" if $DEBUG == 1;

  # get stop codon details
  my $stop_codon_aa = "";
  my $stop_codon =  substr($mutated_cds_3_prime_utr_seq, $stop_gained_position - 3, 3);
  my $stop_codon_seq = Bio::Seq->new( -seq => $stop_codon, -moltype => 'dna', -alphabet => 'dna' );
  my $aa = $stop_codon_seq->translate(undef, undef, undef, $codon_table)->seq();
  if( defined($aa) && exists($aa_conversion{$aa}) ){
    $stop_codon_aa = $aa_conversion{$aa};
  }
  print "stop_codon: $stop_codon($stop_codon_aa)\n" if $DEBUG == 1;

  # get -1 aa details
  my $minus_1_codon = "";
  my $minus_1_aa = "";
  if( $stop_gained_position >= 6 ){
    $minus_1_codon = substr($mutated_cds_3_prime_utr_seq, $stop_gained_position - 6, 3);
    my $minus_1_aa_seq = Bio::Seq->new( -seq => $minus_1_codon, -moltype => 'dna', -alphabet => 'dna' );
    my $aa = $minus_1_aa_seq->translate(undef, undef, undef, $codon_table)->seq();
    if( defined($aa) && exists($aa_conversion{$aa}) ){
      $minus_1_aa = $aa_conversion{$aa};
    }
  }
  print "minus_1_codon: $minus_1_codon($minus_1_aa)\n" if $DEBUG == 1;

  # get -2 aa details
  my $minus_2_codon = ""; 
  my $minus_2_aa = "";
  if( $stop_gained_position >= 9 ){
    $minus_2_codon =  substr($mutated_cds_3_prime_utr_seq, $stop_gained_position - 9, 3);
    my $minus_2_aa_seq = Bio::Seq->new( -seq => $minus_2_codon, -moltype => 'dna', -alphabet => 'dna' );
    my $aa = $minus_2_aa_seq->translate(undef, undef, undef, $codon_table)->seq();
    if( defined($aa) && exists($aa_conversion{$aa}) ){
      $minus_2_aa = $aa_conversion{$aa};
    }
  }
  print "minus_2_codon: $minus_2_codon($minus_2_aa)\n" if $DEBUG == 1;

  # get letter after stop codon
  my $fourth_letter = "N";
  if( length($mutated_cds_3_prime_utr_seq) > $stop_gained_position ){
    $fourth_letter = substr($mutated_cds_3_prime_utr_seq, $stop_gained_position, 1);
    if( !defined($fourth_letter) ){
      print "$hgvsp\n";
      print "$stop_gained_position\n";
      print "$mutated_cds_3_prime_utr_seq\n";
    }
  }
  print "fourth_letter: $fourth_letter\n" if $DEBUG == 1;

  $output_hash->{'Stop_context'} = "$minus_2_codon($minus_2_aa)$minus_1_codon($minus_1_aa)$stop_codon($stop_codon_aa)$fourth_letter";
  $output_hash->{'Next_ATG'} = $next_atg_distance;

  # check if variant is in last exon
  my $last_exon = $exons[-1]; 
  my $last_exon_cds_start = $last_exon->cdna_start($tr) - $start_coding_cdna_location;
  my $last_exon_cds_end = $last_exon->cdna_end($tr) - $start_coding_cdna_location;
  if( $stop_gained_position >= $last_exon_cds_start && $stop_gained_position <= $last_exon_cds_end ){
    $check_last = 1;
  }

  # check if variant is in the last 50bp of the penultimate exon
  if( scalar(@exons) >= 2 ){
    my $second_last_exon = $exons[-2];
    my $second_last_exon_cds_end = $second_last_exon->cdna_end($tr) - $start_coding_cdna_location;
    my $second_last_exon_cds_start = $second_last_exon->cdna_start($tr) - $start_coding_cdna_location;
    my $last_50bp_pos = $second_last_exon_cds_end - 50;
    if( $last_50bp_pos < $second_last_exon_cds_start ){ $last_50bp_pos = $second_last_exon_cds_start; }
    if( $stop_gained_position >= $second_last_exon_cds_end - 50 && $stop_gained_position <= $second_last_exon_cds_end ){
      $check_50bp_second_last = 1;
    }
  }

  # check if the variant location falls in an exon bigger than 407bp
  foreach my $exon (@exons){
    my $exon_cds_start = $exon->cdna_start($tr) - $start_coding_cdna_location;
    my $exon_cds_end = $exon->cdna_end($tr) - $start_coding_cdna_location;
    my $exon_length = $exon->length;
    if($DEBUG == 1){
      my $strand =$tr->strand;
      my $tx_name =$tr->stable_id();
      my $gene = $tr->get_Gene;
      my $gene_name = $gene->external_name();
      my $rank = $exon->rank($tr);
      print "$gene_name\t$tx_name\tEX$rank\t$exon_cds_start\t$exon_cds_end\t$exon_length\n";
    }
    if( $stop_gained_position >= $exon_cds_start && $stop_gained_position <= $exon_cds_end ){
      print " --> stop codon located in the previous exon\n" if $DEBUG == 1;
      if( $exon_length >= 407 ){
        $check_407bp = 1;
      }
    }
  }

  # check if the variant falls within the first 150 bp of the coding region
  my $variant_coding_region = $tv->cds_end if (defined $tv->cds_end);
  if ( defined ($variant_coding_region) && $variant_coding_region + $stop_gained_offset <= 151){
    $check_150bp = 1;
  }

  # check number for introns is more than zerp
  my @introns = $tr->get_all_Introns; 
  my $number_introns = scalar(@introns);
  if ( $number_introns == 0){
    $check_no_introns = 1;
  }

  # if statement to check if any of the rules is true
  my $nmd_pred = "";
  my $nmd_rule = "";

  if ( 0 ) {
  } elsif( $check_no_introns ) {
    $nmd_pred = "canonical_NMD_escaping";
    $nmd_rule = "intronless";
  } elsif( $check_last ) {
    $nmd_pred = "canonical_NMD_escaping";
    $nmd_rule = "last_exon";
  } elsif( $check_50bp_second_last ) {
    $nmd_pred = "canonical_NMD_escaping";
    $nmd_rule = "50bp_penult_exon";
  } elsif( $check_150bp) {
    $nmd_pred = "noncanonical_NMD_escaping";
    $nmd_rule = "first_150bp";
  } elsif( $check_407bp ) {
    $nmd_pred = "noncanonical_NMD_escaping";
    $nmd_rule = "lt_407bp_exon";
  } else {
    $nmd_pred = "putative_NMD_triggering";
    $nmd_rule = "";
  }

  $output_hash->{'NMD_prediction'} = $nmd_pred;
  $output_hash->{'NMD_rule'} = $nmd_rule;

  return $output_hash;

}

1;

