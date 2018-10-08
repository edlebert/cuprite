# frozen_string_literal: true

require "forwardable"

module Capybara::Cuprite
  class Evaluate
    extend Forwardable

    delegate %i(page) => :@targets

    def initialize(targets)
      @targets = targets
    end

    def evaluate(expr, *args)
      response = call(expr, {}, *args)
      process(result: response)
    end

    def evaluate_async(expr, wait_time, *args)
      options = { awaitPromise: true,
                  functionDeclaration: %Q(
                    function() {
                      return new Promise((resolve, reject) => {
                        try {
                          let callback = function(r) { resolve(r) }
                          arguments[arguments.length] = callback
                          #{expr}
                        } catch(error) {
                          reject(error)
                        }
                      });
                    }
                  ) }
      response = call(expr, options, *args)
      process(result: response)
    end

    def execute(expr, *args)
      call(expr, { returnByValue: true }, *args)
      true
    end

    private

    def call(expr, options, *args)
      args = prepare_args(args)
      default_options = { arguments: args,
                          executionContextId: page.execution_context_id,
                          functionDeclaration: %Q(
                            function() { return #{expr} }
                          ) }
      options = default_options.merge(options)
      page.command("Runtime.callFunctionOn", **options)["result"].tap do |response|
        raise JavaScriptError.new(response) if response["subtype"] == "error"
      end
    end

    def prepare_args(args)
      args.map do |arg|
        if arg.is_a?(Node)
          node_id = arg.native.node["nodeId"]
          resolved = page.command("DOM.resolveNode", nodeId: node_id)
          { objectId: resolved["object"]["objectId"] }
        else
          { value: arg }
        end
      end
    end

    def process(result:)
      object_id = result["objectId"]

      case result["type"]
      when "boolean", "number", "string"
        result["value"]
      when "undefined"
        nil
      when "function"
        result["description"]
      when "object"
        case result["subtype"]
        when "node"
          node = page.command("DOM.describeNode", objectId: object_id)["node"]
          { "target_id" => page.target_id, "node" => node }
        when "array"
          traverse_with(object_id, []) { |base, k, v| base.insert(k.to_i, v) }
        when "date"
          result["description"]
        when "null"
          nil
        else
          traverse_with(object_id, {}) { |base, k, v| base.merge(k => v) }
        end
      end
    end

    def traverse_with(object_id, object)
      response = page.command("Runtime.getProperties", objectId: object_id)
      response["result"].reduce(object) do |base, prop|
        next(base) unless prop["enumerable"]
        yield(base, prop["name"], prop.dig("value", "value"))
      end
    end
  end
end
