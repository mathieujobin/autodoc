require "active_support/core_ext"
require "awesome_print"
require "erb"
require "nokogiri"

module Autodoc
  class Document
    def self.render(*args)
      new(*args).render
    end

    attr_reader :example, :transaction

    delegate :method, :request_body, :response_status, :response_header, :response_body_raw, :controller, :action, :request,
      to: :transaction

    def initialize(example, txn)
      @example, @transaction = example, txn
    end

    def render
      ERB.new(Autodoc.configuration.template, nil, "-").result(binding)
    end

    private

    def description
      "#{example.description.capitalize}."
    end

    def path
      example.full_description[%r<(GET|POST|PUT|DELETE) ([^ ]+)>, 2]
    end

    def response_body
      "\n" + JSON.pretty_generate(JSON.parse(response_body_raw))
    rescue JSON::ParserError
      "\n" + Nokogiri::XML(response_body_raw){ |config| config.strict }.to_xml
    rescue Nokogiri::XML::SyntaxError
    end

    def request_body_section
      if has_request_body?
        "\n```\n#{request_body}\n```\n"
      end
    end

    def parameters_section
      if has_validators? && parameters.present?
        "\n### parameters\n#{parameters}\n"
      end
    end

    def param2string params
      param = []
      params.each_pair{|key, val|
        if val.is_a?(Array)
          val.each{|val2|
            param << "#{key}[]=#{val2}"
          }
        elsif val.is_a?(Hash)
          val.each_pair{|key2, val2|
            param << "#{key}[#{key2}]=#{val2}"
          }
        else
          param << "#{key}=#{val}"
        end
      }
      param.join('&')
    end
    def example_get_section 
      if request.GET.present?
        "\n### example GET\n#{param2string(request.GET)}\n"
      end
    end
    
    def example_post_section
      if request.POST.present?
        "\n### example POST\n#{param2string(request.POST)}\n"
      end
    end

    def parameters
      validators.map {|validator| Parameter.new(validator) }.join("\n")
    end

    def has_request_body?
      request_body.present?
    end

    def has_validators?
      !!(defined?(WeakParameters) && validators)
    end

    def validators
      if defined?(Sinatra)
        WeakParameters.stats[method][request.env["PATH_INFO"]].try(:validators)
      else
        WeakParameters.stats[controller][action].try(:validators)
      end
    end

    def response_headers
      Autodoc.configuration.headers.map do |header|
        "\n#{header}: #{response_header(header)}" if response_header(header)
      end.compact.join
    end

    class Parameter
      attr_reader :validator

      def initialize(validator)
        @validator = validator
      end

      def to_s
        if validator.type == :hash and validator.options[:comment]
          validator.options[:comment]
        else
          "#{body}#{payload}"
        end
      end

      private

      def body
        "* `#{validator.key}` #{validator.type}"
      end

      def payload
        string = ""
        string << " (#{assets.join(', ')})" if assets.any?
        string << " - #{validator.options[:description]}" if validator.options[:description]
        string
      end

      def assets
        @assets ||= [required, only, except, comment].compact
      end

      def required
        "required" if validator.required?
      end

      def only
        "only: `#{validator.options[:only].inspect}`" if validator.options[:only]
      end

      def except
        "except: `#{validator.options[:except].inspect}`" if validator.options[:except]
      end
      
      def comment
        "comment: `#{validator.options[:comment].inspect}`" if validator.options[:comment]
      end
    end
  end
end
