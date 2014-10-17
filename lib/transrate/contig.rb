require 'forwardable'

module Transrate

  # A contig in a transcriptome assembly.
  class Contig

    include Enumerable
    extend Forwardable
    def_delegators :@seq, :size, :length
    attr_accessor :seq, :name
    # read-based metrics
    attr_accessor :coverage, :uncovered_bases, :p_uncovered_bases
    attr_accessor :p_seq_true, :p_unique
    attr_accessor :low_uniqueness_bases, :in_bridges
    attr_accessor :p_good, :p_not_segmented
    # reference-based metrics
    attr_accessor :has_crb, :reference_coverage
    attr_accessor :hits

    def initialize(seq, name: nil)
      seq.seq.gsub!("\0", "") # there is probably a better fix than this
      @seq = seq
      @seq.data = nil # no need to store raw fasta string
      @name = seq.respond_to?(:entry_id) ? seq.entry_id : name
      @hits = []
      @reference_coverage = 0
      @has_crb = false
      @in_bridges = 0
      @p_seq_true = 0
      @low_uniqueness_bases = 0
      @p_good = -1
      @uncovered_bases = length
      @p_uncovered_bases = 1
      @p_unique = 0
      @p_not_segmented = 1
      @score = -1
    end

    def each &block
      @seq.seq.each_char &block
    end

    # Get all metrics available for this contig
    def basic_metrics
      basic = {
        :length => length,
        :prop_gc => prop_gc,
        :gc_skew => gc_skew,
        :at_skew => at_skew,
        :cpg_count => cpg_count,
        :cpg_ratio => cpg_ratio,
        :orf_length => orf_length,
        :linguistic_complexity_6 => linguistic_complexity(6),
      }
    end

    def read_metrics
      read = @p_good>=0 ? {
        :in_bridges => in_bridges,
        :p_good => @p_good,
        :p_bases_covered => p_bases_covered,
        :p_seq_true => p_seq_true,
        :score => score,
        :p_unique => p_unique,
        :p_not_segmented => p_not_segmented,
        :expression => coverage
      } : {
        :in_bridges => "NA",
        :p_good => "NA",
        :p_bases_covered => "NA",
        :p_seq_true => "NA",
        :score => "NA",
        :p_unique => p_unique,
        :p_not_segmented => p_not_segmented,
        :expression => coverage
      }
    end

    def comparative_metrics
      reference = @has_crb ? {
        :has_crb => has_crb,
        :reference_coverage => reference_coverage,
        :hits => hits.map{ |h| h.target }.join(";")
      } : {
        :has_crb => false,
        :reference_coverage => "NA",
        :hits => "NA"
      }
    end

    # Base composition of the contig
    #
    # If called and the instance variable @base_composition is nil
    # then call the c method to count the bases and dibases in the sequence
    # then get the info out of the c array and store it in the hash
    # then if it is called again just return the hash as before
    def base_composition
      if @base_composition
        return @base_composition
      end
      # else run the C method
      composition(@seq.seq)
      alphabet = ['a', 'c', 'g', 't', 'n']
      @base_composition = {}
      @dibase_composition = {}
      bases = []
      dibases = []
      alphabet.each do |c|
        bases << "#{c}".to_sym
      end
      alphabet.each do |c|
        alphabet.each do |d|
          dibases << "#{c}#{d}".to_sym
        end
      end
      bases.each_with_index do |a,i|
        @base_composition[a] = base_count(i)
      end
      dibases.each_with_index do |a,i|
        @dibase_composition[a] = dibase_count(i)
      end
      return @base_composition
    end

    # Dibase composition of the contig
    def dibase_composition
      if @dibase_composition
        return @dibase_composition
      end
      base_composition
      @dibase_composition
    end

    # Number of bases that are C
    def bases_c
      base_composition[:c]
    end

    # Proportion of bases that are C
    def prop_c
      bases_c / length.to_f
    end

    # Number of bases that are G
    def bases_g
      base_composition[:g]
    end

    # Proportion of bases that are G
    def prop_g
      bases_g / length.to_f
    end

    # Number of bases that are A
    def bases_a
      base_composition[:a]
    end

    # Proportion of bases that are A
    def prop_a
      bases_a / length.to_f
    end

    # Number of bases that are T
    def bases_t
      base_composition[:t]
    end

    # Proportion of bases that are T
    def prop_t
      bases_t / length.to_f
    end

    def bases_n
      base_composition[:n]
    end

    def prop_n
      bases_n / length.to_f
    end

    # GC
    def bases_gc
      bases_g + bases_c
    end

    def prop_gc
      prop_g + prop_c
    end

    # GC skew
    def gc_skew
      (bases_g - bases_c) / (bases_g + bases_c).to_f
    end

    # AT skew
    def at_skew
      (bases_a - bases_t) / (bases_a + bases_t).to_f
    end

    # CpG count
    def cpg_count
      dibase_composition[:cg] + dibase_composition[:gc]
    end

    # observed-to-expected CpG (C-phosphate-G) ratio
    def cpg_ratio
      r = dibase_composition[:cg] + dibase_composition[:gc]
      r /= (bases_c * bases_g).to_f
      r *= (length - bases_n)
      return r
    end

    # Find the longest orf in the contig
    def orf_length
      return @orf_length if @orf_length
      @orf_length = longest_orf(@seq.seq) # call to C
      return @orf_length
    end

    def linguistic_complexity k
      return kmer_count(k, @seq.seq)/(4**k).to_f # call to C
    end

    def p_bases_covered
      1 - p_uncovered_bases
    end

    def uncovered_bases= n
      @uncovered_bases = n
      @p_uncovered_bases = n / length.to_f
    end

    def p_unique_bases
      (length - low_uniqueness_bases) / length.to_f
    end

    # Contig score (geometric mean of all score components)
    def score
      return @score if @score != -1
      prod =
        [p_bases_covered, 0.01].max * # proportion of bases covered
        [p_not_segmented, 0.01].max * # prob contig has 0 changepoints
        [p_good, 0.01].max * # proportion of reads that mapped good
        [p_seq_true, 0.01].max * # scaled 1 - mean per-base edit distance
        [p_unique, 0.01].max # prop mapQ >= 5
      s = prod ** (1.0 / 5)
      s = 0.01 if !s
      @score = [s, 0.01].max
    end
  end

end
