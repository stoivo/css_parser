# frozen_string_literal: true

require 'forwardable'
require 'set'

module CssParser
  class RuleSet
    # Patterns for specificity calculations
    RE_ELEMENTS_AND_PSEUDO_ELEMENTS = /((^|[\s+>]+)\w+|:(first-line|first-letter|before|after))/i.freeze
    RE_NON_ID_ATTRIBUTES_AND_PSEUDO_CLASSES = /(\.\w+)|(\[\w+)|(:(link|first-child|lang))/i.freeze

    BACKGROUND_PROPERTIES = ['background-color', 'background-image', 'background-repeat', 'background-position', 'background-size', 'background-attachment'].freeze
    LIST_STYLE_PROPERTIES = ['list-style-type', 'list-style-position', 'list-style-image'].freeze
    FONT_STYLE_PROPERTIES = ['font-style', 'font-variant', 'font-weight', 'font-size', 'line-height', 'font-family'].freeze
    BORDER_STYLE_PROPERTIES = ['border-width', 'border-style', 'border-color'].freeze
    BORDER_PROPERTIES = ['border', 'border-left', 'border-right', 'border-top', 'border-bottom'].freeze

    NUMBER_OF_DIMENSIONS = 4

    DIMENSIONS = [
      ['margin', %w[margin-top margin-right margin-bottom margin-left]],
      ['padding', %w[padding-top padding-right padding-bottom padding-left]],
      ['border-color', %w[border-top-color border-right-color border-bottom-color border-left-color]],
      ['border-style', %w[border-top-style border-right-style border-bottom-style border-left-style]],
      ['border-width', %w[border-top-width border-right-width border-bottom-width border-left-width]]
    ].freeze

    WHITESPACE_REPLACEMENT = '___SPACE___'

    extend Forwardable

    # optional field for storing source reference
    # File offset range
    attr_reader :offset
    # the local or remote location
    attr_accessor :filename

    # Array of selector strings.
    attr_reader :selectors

    # Integer with the specificity to use for this RuleSet.
    attr_accessor :specificity

    # @!method add_declaration!
    #   @see CssParser::RuleSet::Declarations#add_declaration!
    # @!method delete
    #   @see CssParser::RuleSet::Declarations#delete
    def_delegators :declarations, :add_declaration!, :delete
    alias []= add_declaration!
    alias remove_declaration! delete

    def initialize(selectors: nil, block: nil, offset: nil, filename: nil, specificity: nil)
      @selectors = []
      @specificity = specificity

      unless offset.nil? == filename.nil?
        raise ArgumentError, 'require both offset and filename or no offset and no filename'
      end

      @offset = offset
      @filename = filename

      parse_selectors!(selectors) if selectors
      parse_declarations!(block)
    end

    # Get the value of a property
    def get_value(property)
      return '' unless (value = declarations[property])

      "#{value};"
    end
    alias [] get_value

    # Iterate through selectors.
    #
    # Options
    # -  +force_important+ -- boolean
    #
    # ==== Example
    #   ruleset.each_selector do |sel, dec, spec|
    #     ...
    #   end
    def each_selector(options = {}) # :yields: selector, declarations, specificity
      decs = declarations.to_s(options)
      if @specificity
        @selectors.each { |sel| yield sel.strip, decs, @specificity }
      else
        @selectors.each { |sel| yield sel.strip, decs, CssParser.calculate_specificity(sel) }
      end
    end

    # Iterate through declarations.
    def each_declaration # :yields: property, value, is_important
      declarations.each do |property_name, value|
        yield property_name, value.value, value.important
      end
    end

    # Return all declarations as a string.
    def declarations_to_s(options = {})
      declarations.to_s(options)
    end

    # Return the CSS rule set as a string.
    def to_s
      "#{@selectors.join(',')} { #{declarations} }"
    end

    # Split shorthand declarations (e.g. +margin+ or +font+) into their constituent parts.
    def expand_shorthand!
      # border must be expanded before dimensions
      expand_border_shorthand!
      expand_dimensions_shorthand!
      expand_font_shorthand!
      expand_background_shorthand!
      expand_list_style_shorthand!
    end

    # Convert shorthand background declarations (e.g. <tt>background: url("chess.png") gray 50% repeat fixed;</tt>)
    # into their constituent parts.
    #
    # See http://www.w3.org/TR/CSS21/colors.html#propdef-background
    def expand_background_shorthand! # :nodoc:
      return unless (declaration = declarations['background'])

      value = declaration.value.dup

      replacement =
        if value.match(CssParser::RE_INHERIT)
          BACKGROUND_PROPERTIES.to_h { |key| [key, 'inherit'] }
        else
          {
            'background-image' => value.slice!(CssParser::RE_IMAGE),
            'background-attachment' => value.slice!(CssParser::RE_SCROLL_FIXED),
            'background-repeat' => value.slice!(CssParser::RE_REPEAT),
            'background-color' => value.slice!(CssParser::RE_COLOUR),
            'background-size' => extract_background_size_from(value),
            'background-position' => value.slice!(CssParser::RE_BACKGROUND_POSITION)
          }
        end

      declarations.replace_declaration!('background', replacement, preserve_importance: true)
    end

    def extract_background_size_from(value)
      size = value.slice!(CssParser::RE_BACKGROUND_SIZE)

      size.sub(%r{^\s*/\s*}, '') if size
    end

    # Split shorthand border declarations (e.g. <tt>border: 1px red;</tt>)
    # Additional splitting happens in expand_dimensions_shorthand!
    def expand_border_shorthand! # :nodoc:
      BORDER_PROPERTIES.each do |k|
        next unless (declaration = declarations[k])

        value = declaration.value.dup

        replacement = {
          "#{k}-width" => value.slice!(CssParser::RE_BORDER_UNITS),
          "#{k}-color" => value.slice!(CssParser::RE_COLOUR),
          "#{k}-style" => value.slice!(CssParser::RE_BORDER_STYLE)
        }

        declarations.replace_declaration!(k, replacement, preserve_importance: true)
      end
    end

    # Split shorthand dimensional declarations (e.g. <tt>margin: 0px auto;</tt>)
    # into their constituent parts.  Handles margin, padding, border-color, border-style and border-width.
    def expand_dimensions_shorthand! # :nodoc:
      DIMENSIONS.each do |property, (top, right, bottom, left)|
        next unless (declaration = declarations[property])

        value = declaration.value.dup

        # RGB and HSL values in borders are the only units that can have spaces (within params).
        # We cheat a bit here by stripping spaces after commas in RGB and HSL values so that we
        # can split easily on spaces.
        #
        # TODO: rgba, hsl, hsla
        value.gsub!(RE_COLOUR) { |c| c.gsub(/(\s*,\s*)/, ',') }

        matches = split_value_preserving_function_whitespace(value)

        case matches.length
        when 1
          values = matches.to_a * 4
        when 2
          values = matches.to_a * 2
        when 3
          values = matches.to_a
          values << matches[1] # left = right
        when 4
          values = matches.to_a
        else
          raise ArgumentError, "Cannot parse #{value}"
        end

        replacement = [top, right, bottom, left].zip(values).to_h

        declarations.replace_declaration!(property, replacement, preserve_importance: true)
      end
    end

    class FontScanner
      FONT_STYLES = Set.new(['normal', 'italic', 'oblique', 'inherit'])
      FONT_VARIANTS = Set.new(['normal', 'small-caps', 'inherit'])
      FONT_WEIGHTS = Set.new(
        [
          'normal', 'bold', 'bolder', 'lighter',
          '100', '200', '300', '400', '500', '600', '700', '800', '900',
          'inherit'
        ]
      )
      ABSOLUTE_SIZES = Set.new(
        ['xx-small', 'x-small', 'small', 'medium', 'large', 'x-large', 'xx-large']
      )
      RELATIVE_SIZES = Set.new(['smaller', 'larger'])

      attr_reader :current, :pos, :tokens

      def initialize(tokens)
        @token_scanner = Crass::TokenScanner.new(tokens)
      end

      def peek = @token_scanner.peek
      def consume = @token_scanner.consume
      def collect(&block) = @token_scanner.collect(&block)

      private def consume_iden_str(value)
        consume if peek[:node] == :ident && peek[:value] == value
      end

      private def consume_iden_set(set)
        consume if peek[:node] == :ident && set.member?(peek[:value])
      end

      private def consume_type(type)
        consume if peek[:node] == type
      end

      def consume_font_style = consume_iden_set(FONT_STYLES)
      def consume_font_variant = consume_iden_set(FONT_VARIANTS)
      def consume_font_weight = consume_iden_set(FONT_WEIGHTS) || consume_type(:number)
      def consume_absulute_size = consume_iden_set(ABSOLUTE_SIZES)
      def consume_relative_size = consume_iden_set(RELATIVE_SIZES)
      def consume_length = consume_type(:dimension)
      def consume_percentage = consume_type(:percentage)
      def consume_number = consume_type(:percentage)
      def consume_inherit = consume_iden_str('inherit')
      def consume_normal = consume_iden_str('normal')

      def consume_font_style_variant_weight
        consume_font_style || consume_font_variant || consume_font_weight
      end

      def consume_font_size
        consume_absulute_size ||
          consume_relative_size ||
          consume_length ||
          consume_percentage ||
          consume_inherit
      end

      def consume_line_height
        consume_normal ||
          consume_number ||
          consume_length ||
          consume_percentage ||
          consume_inherit
      end

      def consume_system_fonts
        consume_iden_str('caption') ||
          consume_iden_str('icon') ||
          consume_iden_str('menu') ||
          consume_iden_str('message-box') ||
          consume_iden_str('small-caption') ||
          consume_iden_str('status-bar') ||
          consume_inherit
      end
    end

    # Convert shorthand font declarations (e.g. <tt>font: 300 italic 11px/14px verdana, helvetica, sans-serif;</tt>)
    # into their constituent parts.
    def expand_font_shorthand! # :nodoc:
      return unless (declaration = declarations['font'])

      # reset properties to 'normal' per http://www.w3.org/TR/CSS21/fonts.html#font-shorthand
      font_props = {
        'font-style' => 'normal',
        'font-variant' => 'normal',
        'font-weight' => 'normal',
        'font-size' => 'normal',
        'line-height' => 'normal'
      }
      tokens = Crass::Tokenizer
               .tokenize(declaration.value.dup)
               .reject { _1[:node] == :whitespace }
      scanner = FontScanner.new(tokens)

      if scanner.consume_system_fonts
        # nothing we can do with system fonts
        return
      end

      while (token = scanner.consume_font_style_variant_weight)
        if FontScanner::FONT_STYLES.member?(token[:value])
          font_props['font-style'] = token[:value]
        end
        if FontScanner::FONT_VARIANTS.member?(token[:value])
          font_props['font-variant'] = token[:value]
        end
        # we use raw from font wights since it include numbers
        if FontScanner::FONT_WEIGHTS.member?(token[:raw])
          font_props['font-weight'] = token[:raw]
        end
      end

      font_size = scanner.consume_font_size
      font_props['font-size'] = font_size[:raw]

      if scanner.peek[:node] == :delim && scanner.peek[:value] == '/'
        scanner.consume
        line_height = scanner.consume_line_height
        font_props['line-height'] = line_height[:raw]
      end

      rest = scanner.collect do
        while scanner.consume
          # nothing, just collect the rest
        end
      end
      if rest.any?
        font_props['font-family'] = Crass::Parser.stringify(rest)
      end

      declarations.replace_declaration!('font', font_props, preserve_importance: true)
    end

    # Convert shorthand list-style declarations (e.g. <tt>list-style: lower-alpha outside;</tt>)
    # into their constituent parts.
    #
    # See http://www.w3.org/TR/CSS21/generate.html#lists
    def expand_list_style_shorthand! # :nodoc:
      return unless (declaration = declarations['list-style'])

      value = declaration.value.dup

      replacement =
        if value =~ CssParser::RE_INHERIT
          LIST_STYLE_PROPERTIES.to_h { |key| [key, 'inherit'] }
        else
          {
            'list-style-type' => value.slice!(CssParser::RE_LIST_STYLE_TYPE),
            'list-style-position' => value.slice!(CssParser::RE_INSIDE_OUTSIDE),
            'list-style-image' => value.slice!(CssParser::URI_RX_OR_NONE)
          }
        end

      declarations.replace_declaration!('list-style', replacement, preserve_importance: true)
    end

    # Create shorthand declarations (e.g. +margin+ or +font+) whenever possible.
    def create_shorthand!
      create_background_shorthand!
      create_dimensions_shorthand!
      # border must be shortened after dimensions
      create_border_shorthand!
      create_font_shorthand!
      create_list_style_shorthand!
    end

    # Combine several properties into a shorthand one
    def create_shorthand_properties!(properties, shorthand_property) # :nodoc:
      values = []
      properties_to_delete = []
      properties.each do |property|
        next unless (declaration = declarations[property])
        next if declaration.important

        values << declaration.value
        properties_to_delete << property
      end

      return if values.length <= 1

      properties_to_delete.each do |property|
        declarations.delete(property)
      end

      declarations[shorthand_property] = values.join(' ')
    end

    # Looks for long format CSS background properties (e.g. <tt>background-color</tt>) and
    # converts them into a shorthand CSS <tt>background</tt> property.
    #
    # Leaves properties declared !important alone.
    def create_background_shorthand! # :nodoc:
      # When we have a background-size property we must separate it and distinguish it from
      # background-position by preceding it with a backslash. In this case we also need to
      # have a background-position property, so we set it if it's missing.
      # http://www.w3schools.com/cssref/css3_pr_background.asp
      if (declaration = declarations['background-size']) && !declaration.important
        declarations['background-position'] ||= '0% 0%'
        declaration.value = "/ #{declaration.value}"
      end

      create_shorthand_properties! BACKGROUND_PROPERTIES, 'background'
    end

    # Combine border-color, border-style and border-width into border
    # Should be run after create_dimensions_shorthand!
    #
    # TODO: this is extremely similar to create_background_shorthand! and should be combined
    def create_border_shorthand! # :nodoc:
      values = BORDER_STYLE_PROPERTIES.map do |property|
        next unless (declaration = declarations[property])
        next if declaration.important
        # can't merge if any value contains a space (i.e. has multiple values)
        # we temporarily remove any spaces after commas for the check (inside rgba, etc...)
        next if declaration.value.gsub(/,\s/, ',').strip =~ /\s/

        declaration.value
      end.compact

      return if values.size != BORDER_STYLE_PROPERTIES.size

      BORDER_STYLE_PROPERTIES.each do |property|
        declarations.delete(property)
      end

      declarations['border'] = values.join(' ')
    end

    # Looks for long format CSS dimensional properties (margin, padding, border-color, border-style and border-width)
    # and converts them into shorthand CSS properties.
    def create_dimensions_shorthand! # :nodoc:
      return if declarations.size < NUMBER_OF_DIMENSIONS

      DIMENSIONS.each do |property, dimensions|
        values = [:top, :right, :bottom, :left].each_with_index.with_object({}) do |(side, index), result|
          next unless (declaration = declarations[dimensions[index]])

          result[side] = declaration.value
        end

        # All four dimensions must be present
        next if values.size != dimensions.size

        new_value = values.values_at(*compute_dimensions_shorthand(values)).join(' ').strip
        declarations[property] = new_value unless new_value.empty?

        # Delete the longhand values
        dimensions.each { |d| declarations.delete(d) }
      end
    end

    # Looks for long format CSS font properties (e.g. <tt>font-weight</tt>) and
    # tries to convert them into a shorthand CSS <tt>font</tt> property.  All
    # font properties must be present in order to create a shorthand declaration.
    def create_font_shorthand! # :nodoc:
      return unless FONT_STYLE_PROPERTIES.all? { |prop| declarations.key?(prop) }

      new_value = String.new
      ['font-style', 'font-variant', 'font-weight'].each do |property|
        unless declarations[property].value == 'normal'
          new_value << declarations[property].value << ' '
        end
      end

      new_value << declarations['font-size'].value

      unless declarations['line-height'].value == 'normal'
        new_value << '/' << declarations['line-height'].value
      end

      new_value << ' ' << declarations['font-family'].value

      declarations['font'] = new_value.gsub(/\s+/, ' ')

      FONT_STYLE_PROPERTIES.each { |prop| declarations.delete(prop) }
    end

    # Looks for long format CSS list-style properties (e.g. <tt>list-style-type</tt>) and
    # converts them into a shorthand CSS <tt>list-style</tt> property.
    #
    # Leaves properties declared !important alone.
    def create_list_style_shorthand! # :nodoc:
      create_shorthand_properties! LIST_STYLE_PROPERTIES, 'list-style'
    end

  private

    attr_accessor :declarations

    def compute_dimensions_shorthand(values)
      # All four sides are equal, returning single value
      return [:top] if values.values.uniq.count == 1

      # `/* top | right | bottom | left */`
      return [:top, :right, :bottom, :left] if values[:left] != values[:right]

      # Vertical are the same & horizontal are the same, `/* vertical | horizontal */`
      return [:top, :left] if values[:top] == values[:bottom]

      [:top, :left, :bottom]
    end

    def parse_declarations!(block) # :nodoc:
      case block
      when nil
        self.declarations = Declarations.new
      when Declarations
        self.declarations = block
      when String
        Crass.parse_properties(block)
             .then { ParserFx.create_declaration_from_properties(_1) }
             .then { self.declarations = _1 }
      end
    end

    #--
    # TODO: way too simplistic
    #++
    def parse_selectors!(selectors) # :nodoc:
      @selectors = selectors.split(',').map do |s|
        s.gsub!(/\s+/, ' ')
        s.strip!
        s
      end
    end

    def split_value_preserving_function_whitespace(value)
      split_value = value.gsub(RE_FUNCTIONS) do |c|
        c.gsub!(/\s+/, WHITESPACE_REPLACEMENT)
        c
      end

      matches = split_value.strip.split(/\s+/)

      matches.each do |c|
        c.gsub!(WHITESPACE_REPLACEMENT, ' ')
      end
    end
  end
end
