# frozen_string_literal: true
require "graphql/types/string"

module GraphQL
  class Schema
    # Mutations that extend this base class get some conventions added for free:
    #
    # - An argument called `clientMutationId` is _always_ added, but it's not passed
    #   to the resolve method. The value is re-inserted to the response. (It's for
    #   client libraries to manage optimistic updates.)
    # - The returned object type always has a field called `clientMutationId` to support that.
    # - The mutation accepts one argument called `input`, `argument`s defined in the mutation
    #   class are added to that input object, which is generated by the mutation.
    #
    # These conventions were first specified by Relay Classic, but they come in handy:
    #
    # - `clientMutationId` supports optimistic updates and cache rollbacks on the client
    # - using a single `input:` argument makes it easy to post whole JSON objects to the mutation
    #   using one GraphQL variable (`$input`) instead of making a separate variable for each argument.
    #
    # @see {GraphQL::Schema::Mutation} for an example, it's basically the same.
    #
    class RelayClassicMutation < GraphQL::Schema::Mutation
      # The payload should always include this field
      field(:client_mutation_id, String, "A unique identifier for the client performing the mutation.")
      # Relay classic default:
      null(true)

      # Override {GraphQL::Schema::Resolver#resolve_with_support} to
      # delete `client_mutation_id` from the kwargs.
      def resolve_with_support(**inputs)
        # Without the interpreter, the inputs are unwrapped by an instrumenter.
        # But when using the interpreter, no instrumenters are applied.
        if context.interpreter?
          input = inputs[:input].to_kwargs

          new_extras = field ? field.extras : []
          all_extras = self.class.extras + new_extras

          # Transfer these from the top-level hash to the
          # shortcutted `input:` object
          all_extras.each do |ext|
            # It's possible that the `extra` was not passed along by this point,
            # don't re-add it if it wasn't given here.
            if inputs.key?(ext)
              input[ext] = inputs[ext]
            end
          end
        else
          input = inputs
        end

        if input
          # This is handled by Relay::Mutation::Resolve, a bit hacky, but here we are.
          input_kwargs = input.to_h
          client_mutation_id = input_kwargs.delete(:client_mutation_id)
        else
          # Relay Classic Mutations with no `argument`s
          # don't require `input:`
          input_kwargs = {}
        end

        return_value = if input_kwargs.any?
          super(**input_kwargs)
        else
          super()
        end

        # Again, this is done by an instrumenter when using non-interpreter execution.
        if context.interpreter?
          context.schema.after_lazy(return_value) do |return_hash|
            # It might be an error
            if return_hash.is_a?(Hash)
              return_hash[:client_mutation_id] = client_mutation_id
            end
            return_hash
          end
        else
          return_value
        end
      end

      class << self

        # Also apply this argument to the input type:
        def argument(*args, **kwargs, &block)
          it = input_type # make sure any inherited arguments are already added to it
          arg = super

          # This definition might be overriding something inherited;
          # if it is, remove the inherited definition so it's not confused at runtime as having multiple definitions
          prev_args = it.own_arguments[arg.graphql_name]
          case prev_args
          when GraphQL::Schema::Argument
            if prev_args.owner != self
              it.own_arguments.delete(arg.graphql_name)
            end
          when Array
            prev_args.reject! { |a| a.owner != self }
            if prev_args.empty?
              it.own_arguments.delete(arg.graphql_name)
            end
          end

          it.add_argument(arg)
          arg
        end

        # The base class for generated input object types
        # @param new_class [Class] The base class to use for generating input object definitions
        # @return [Class] The base class for this mutation's generated input object (default is {GraphQL::Schema::InputObject})
        def input_object_class(new_class = nil)
          if new_class
            @input_object_class = new_class
          end
          @input_object_class || (superclass.respond_to?(:input_object_class) ? superclass.input_object_class : GraphQL::Schema::InputObject)
        end

        # @param new_input_type [Class, nil] If provided, it configures this mutation to accept `new_input_type` instead of generating an input type
        # @return [Class] The generated {Schema::InputObject} class for this mutation's `input`
        def input_type(new_input_type = nil)
          if new_input_type
            @input_type = new_input_type
          end
          @input_type ||= generate_input_type
        end

        # Extend {Schema::Mutation.field_options} to add the `input` argument
        def field_options
          sig = super
          # Arguments were added at the root, but they should be nested
          sig[:arguments].clear
          sig[:arguments][:input] = { type: input_type, required: true, description: "Parameters for #{graphql_name}" }
          sig
        end

        private

        # Generate the input type for the `input:` argument
        # To customize how input objects are generated, override this method
        # @return [Class] a subclass of {.input_object_class}
        def generate_input_type
          mutation_args = all_argument_definitions
          mutation_name = graphql_name
          mutation_class = self
          Class.new(input_object_class) do
            graphql_name("#{mutation_name}Input")
            description("Autogenerated input type of #{mutation_name}")
            mutation(mutation_class)
            # these might be inherited:
            mutation_args.each do |arg|
              add_argument(arg)
            end
            argument :client_mutation_id, String, "A unique identifier for the client performing the mutation.", required: false
          end
        end
      end

      private

      def authorize_arguments(args, values)
        # remove the `input` wrapper to match values
        input_args = args["input"].type.unwrap.arguments(context)
        super(input_args, values)
      end
    end
  end
end
