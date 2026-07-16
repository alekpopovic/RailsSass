require "csv"

module Products
  module Analytics
    class CsvExporter
      HEADERS = [ "Report ID", "Name", "Description", "Created at" ].freeze
      FORMULA_PREFIX = /\A(?:[\t\r]|\s*[=+\-@])/

      def initialize(report)
        @report = report
      end

      def call
        unless report&.persisted? && Current.organization&.id == report.organization_id
          raise ActiveRecord::RecordNotFound
        end

        CSV.generate(force_quotes: true) do |csv|
          csv << HEADERS
          csv << [
            report.public_id,
            spreadsheet_safe(report.name),
            spreadsheet_safe(report.description),
            report.created_at.utc.iso8601(6)
          ]
        end
      end

      private
        attr_reader :report

        def spreadsheet_safe(value)
          string = value.to_s
          FORMULA_PREFIX.match?(string) ? "'#{string}" : string
        end
    end
  end
end
