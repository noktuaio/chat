require 'csv'

module CampaignImports
  class Parser
    ParsedFile = Struct.new(:headers, :rows, :format, keyword_init: true)
    ParsedRow = Struct.new(:row_number, :values, keyword_init: true)

    SUPPORTED_FORMATS = %w[csv xlsx].freeze

    def initialize(attachment, filename:)
      @attachment = attachment
      @filename = filename.to_s
    end

    def perform
      raise ArgumentError, 'unsupported_file_format' unless SUPPORTED_FORMATS.include?(format)

      format == 'csv' ? parse_csv : parse_xlsx
    end

    private

    def parse_csv
      rows = CSV.parse(read_source, liberal_parsing: true)
      headers = normalize_headers(rows.shift || [])
      parsed_rows = rows.each_with_index.map do |row, index|
        ParsedRow.new(row_number: index + 2, values: Array(row).map(&:to_s))
      end

      ParsedFile.new(headers: headers, rows: parsed_rows, format: format)
    end

    def parse_xlsx
      rows = CampaignImports::XlsxReader.new(read_source).rows
      headers = normalize_headers(rows.shift&.values || [])
      parsed_rows = rows.map do |row|
        ParsedRow.new(row_number: row.number, values: row.values)
      end

      ParsedFile.new(headers: headers, rows: parsed_rows, format: format)
    end

    def normalize_headers(headers)
      Array(headers).map.with_index do |header, index|
        value = header.to_s
        value = value.delete_prefix("\uFEFF") if index.zero?
        value
      end
    end

    def read_source
      if @attachment.respond_to?(:open)
        @attachment.open do |file|
          file.binmode
          return file.read
        end
      end

      @attachment.respond_to?(:read) ? @attachment.read : @attachment.to_s
    end

    def format
      @format ||= File.extname(@filename).delete('.').downcase
    end
  end
end
