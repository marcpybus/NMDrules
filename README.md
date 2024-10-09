### NMDrules

#### Motivation

 - NMD prediction is becoming increasingly important for understanding the actual molecular mechanism driving gene-disease association.  
 - Protein truncating variants (PTVs) that escape NMD can exert their pathogenic effects through gain-of-function or dominant-negative mechanisms. Unfortunately, they are often confused with loss-of-function variants, which can lead to incorrect genetic diagnosis.
 - After noticing the shortcomings in predicting NMD escape variants of open-source variant annotators (e.g. VEP NMD plugin, SnpEff, LOFTEE) or the difficult integration of specialised software (i. aenmd, NMDEscPredictor, NMDetective, ALoFT) into annotation pipelines, I decided to implement a simple VEP plugin myself that performs NMD prediction of stop codon generating variants (i.e. stop_gained, stop_loss, some frameshift variants).  
 - In addition to applying the current canonical and non-canonical rules for NMD prediction, the plugin extracts information about the genomic context surrounding the generated stop codon and leverages an hypothetical translation reinitiation.

#### Description

This is a plugin for Ensembl Variant Effect Predictor (VEP) software that predicts whether a stop codon generating variant (i.e. stop_gained, stop_loss, some frameshift variants) triggers nonsense-mediated mRNA decay (`putative_NMD_triggering`) or not (`canonical_NMD_escaping`, `noncanonical_NMD_escaping`) based on the following rules (1):

* The variant is located in an intronless transcript: `canonical_NMD_escaping:intronless`
* The variant is located in the last exon of the transcript: `canonical_NMD_escaping:last_exon`
* The variant is located within the last 50 bp of the penultimate exon: `canonical_NMD_escaping:50bp_penult_exon`
* The variant is located within the first 150 coding bases in the transcript: `noncanonical_NMD_escaping:first_150bp`
* The variant is located in an exon larger than 407 bp: `noncanonical_NMD_escaping:lt_407bp_exon`

The plugin also shows the 2 codons/amino acids before the novel stop codon, plus the next nucleotide, for a detailed analysis, as they may influence the NMD efficiency (2): e.g. `GCC(Ala)CTG(Leu)TGA(Stop)C`

Finally, it calculates the distance in amino acids to the next metionine (Met, start codon) after the stop codon to leverage an hypothetical translation reinitiation (3). 

Annotation format: 
`nmd_prediction:rule_used:-2codon(-2aa)-1codon(-1aa)stop_codon(Stop)fourth_letter:distance_in_aa_to_next_Met`

Example:    10-102509528-C-CG 	PAX2(NM_000278.5):c.76dup:p.Val26GlyfsTer28
`NMDrules => noncanonical_NMD_escaping:first_150bp:GCC(Ala)CTG(Leu)TGA(Stop)C:573`

The plugin starts by filtering in all variants with a stop codon (Ter) in their HGVSp notation. Exceptions are synonymous variants at the stop codon (e.g. p.Ter811=) or when no stop codon is inferred downstream of a frameshift variant (e.g. p.Ter257GlufsTer?). It then internally applies the mutation to the original cDNA to determine the location of the new stop codon, always taking into account all insertions and deletions contained within the cDNA sequence.  

Splicing variants and deletions involving intronic regions are not considered, as VEP cannot internally infer the mutated protein.

This plugin has been tested on all the [gnomAD 2.1.1 exomes](https://storage.googleapis.com/gcp-public-data--gnomad/release/2.1.1/vcf/exomes/gnomad.exomes.r2.1.1.sites.vcf.bgz) variants without throwing any errors. Be aware that more complex variants may cause unobserved bugs.

#### References

1. The impact of nonsense-mediated mRNA decay on genetic disease, gene editing and cancer immunotherapy (Lindeboomet al. 2019, Nature Genetics)
2. Systematic analysis of nonsense variants uncovers peptide release rate as a novel modifier of nonsense-mediated mRNA decay efficiency (Kolokada et al. 2024, bioRxiv)
3. Advanced variant classification framework reduces the false positive rate of predicted loss-of-function variants in population sequencing data (Singer-Berk et al. 2023, Am J Hum Genet)

### Usage

```
mv NMDrules.pm  ~/.vep/Plugins
./vep -i variations.vcf --plugin NMDrules
```

### Credit

@marcpybus - https://github.com/marcpybus/

