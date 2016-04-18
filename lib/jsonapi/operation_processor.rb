module JSONAPI
  class OperationProcessor
    include Callbacks
    define_jsonapi_resources_callbacks :find,
                                       :show,
                                       :show_relationship,
                                       :show_related_resource,
                                       :show_related_resources,
                                       :create_resource,
                                       :remove_resource,
                                       :replace_fields,
                                       :replace_to_one_relationship,
                                       :replace_polymorphic_to_one_relationship,
                                       :create_to_many_relationship,
                                       :replace_to_many_relationship,
                                       :remove_to_many_relationship,
                                       :remove_to_one_relationship,
                                       :operation

    class << self
      def operation_processor_instance_for(resource_klass, operation_type, params)
        _operation_processor_from_resource_type(resource_klass).new(resource_klass, operation_type, params)
      end

      def _operation_processor_from_resource_type(resource_klass)
        operation_processor = resource_klass.name.gsub(/Resource$/,'OperationProcessor').safe_constantize
        if operation_processor.nil?
          operation_processor = JSONAPI.configuration.default_operation_processor_klass
        end

        operation_processor
      end

      def transactional(operation_type)
        case operation_type
          when :find, :show, :show_related_resource, :show_related_resources
            false
          else
            true
        end
      end
    end

    attr_reader :resource_klass, :operation_type, :params, :context, :result, :result_options

    def initialize(resource_klass, operation_type, params)
      @resource_klass = resource_klass
      @operation_type = operation_type
      @params = params
      @context = params[:context]
      @result = nil
      @result_options = {}
    end

    def process
      run_callbacks :operation do
        run_callbacks operation_type do
          @result = send(operation_type)
        end
      end

    rescue JSONAPI::Exceptions::Error => e
      @result = JSONAPI::ErrorsOperationResult.new(e.errors[0].code, e.errors)
    end

    def find
      filters = params[:filters]
      include_directives = params[:include_directives]
      sort_criteria = params.fetch(:sort_criteria, [])
      paginator = params[:paginator]

      verified_filters = resource_klass.verify_filters(filters, context)
      resource_records = resource_klass.find(verified_filters,
                                             context: context,
                                             include_directives: include_directives,
                                             sort_criteria: sort_criteria,
                                             paginator: paginator)

      page_options = {}
      if (JSONAPI.configuration.top_level_meta_include_record_count ||
        (paginator && paginator.class.requires_record_count))
        page_options[:record_count] = resource_klass.find_count(verified_filters,
                                                                context: context,
                                                                include_directives: include_directives)
      end

      if (JSONAPI.configuration.top_level_meta_include_page_count && page_options[:record_count])
        page_options[:page_count] = paginator.calculate_page_count(page_options[:record_count])
      end

      if JSONAPI.configuration.top_level_links_include_pagination && paginator
        page_options[:pagination_params] = paginator.links_page_params(page_options)
      end

      JSONAPI::ResourcesOperationResult.new(:ok,
                                            resource_records,
                                            page_options)
    end

    def show
      include_directives = params[:include_directives]
      id = params[:id]

      key = resource_klass.verify_key(id, context)

      resource_record = resource_klass.find_by_key(key,
                                                   context: context,
                                                   include_directives: include_directives)

      JSONAPI::ResourceOperationResult.new(:ok, resource_record)
    end

    def show_relationship
      parent_key = params[:parent_key]
      relationship_type = params[:relationship_type].to_sym

      parent_resource = resource_klass.find_by_key(parent_key, context: context)

      JSONAPI::LinksObjectOperationResult.new(:ok,
                                              parent_resource,
                                              resource_klass._relationship(relationship_type))
    end

    def show_related_resource
      source_klass = params[:source_klass]
      source_id = params[:source_id]
      relationship_type = params[:relationship_type].to_sym

      source_resource = source_klass.find_by_key(source_id, context: context)

      related_resource = source_resource.public_send(relationship_type)

      JSONAPI::ResourceOperationResult.new(:ok, related_resource)
    end

    def show_related_resources
      source_klass = params[:source_klass]
      source_id = params[:source_id]
      relationship_type = params[:relationship_type]
      filters = params[:filters]
      sort_criteria = params[:sort_criteria]
      paginator = params[:paginator]

      source_resource ||= source_klass.find_by_key(source_id, context: context)

      related_resources = source_resource.public_send(relationship_type,
                                                      filters:  filters,
                                                      sort_criteria: sort_criteria,
                                                      paginator: paginator)

      if ((JSONAPI.configuration.top_level_meta_include_record_count) ||
          (paginator && paginator.class.requires_record_count) ||
          (JSONAPI.configuration.top_level_meta_include_page_count))
        related_resource_records = source_resource.public_send("records_for_" + relationship_type)
        records = resource_klass.filter_records(filters, {},
                                                related_resource_records)

        record_count = records.count(:all)
      end

      if (JSONAPI.configuration.top_level_meta_include_page_count && record_count)
        page_count = paginator.calculate_page_count(record_count)
      end

      pagination_params = if paginator && JSONAPI.configuration.top_level_links_include_pagination
                            page_options = {}
                            page_options[:record_count] = record_count if paginator.class.requires_record_count
                            paginator.links_page_params(page_options)
                          else
                            {}
                          end

      opts = {}
      opts.merge!(pagination_params: pagination_params) if JSONAPI.configuration.top_level_links_include_pagination
      opts.merge!(record_count: record_count) if JSONAPI.configuration.top_level_meta_include_record_count
      opts.merge!(page_count: page_count) if JSONAPI.configuration.top_level_meta_include_page_count

      JSONAPI::RelatedResourcesOperationResult.new(:ok, source_resource, relationship_type, related_resources, opts)
    end

    def create_resource
      data = params[:data]

      resource = resource_klass.create(context)
      result = resource.replace_fields(data)

      JSONAPI::ResourceOperationResult.new((result == :completed ? :created : :accepted), resource)
    end

    def remove_resource
      resource_id = params[:resource_id]

      resource = resource_klass.find_by_key(resource_id, context: context)
      result = resource.remove

      JSONAPI::OperationResult.new(result == :completed ? :no_content : :accepted)
    end

    def replace_fields
      resource_id = params[:resource_id]
      data = params[:data]

      resource = resource_klass.find_by_key(resource_id, context: context)
      result = resource.replace_fields(data)

      JSONAPI::ResourceOperationResult.new(result == :completed ? :ok : :accepted, resource)
    end

    def replace_to_one_relationship
      resource_id = params[:resource_id]
      relationship_type = params[:relationship_type].to_sym
      key_value = params[:key_value]

      resource = resource_klass.find_by_key(resource_id, context: context)
      result = resource.replace_to_one_link(relationship_type, key_value)

      JSONAPI::OperationResult.new(result == :completed ? :no_content : :accepted)
    end

    def replace_polymorphic_to_one_relationship
      resource_id = params[:resource_id]
      relationship_type = params[:relationship_type].to_sym
      key_value = params[:key_value]
      key_type = params[:key_type]

      resource = resource_klass.find_by_key(resource_id, context: context)
      result = resource.replace_polymorphic_to_one_link(relationship_type, key_value, key_type)

      JSONAPI::OperationResult.new(result == :completed ? :no_content : :accepted)
    end

    def create_to_many_relationship
      resource_id = params[:resource_id]
      relationship_type = params[:relationship_type].to_sym
      data = params[:data]

      resource = resource_klass.find_by_key(resource_id, context: context)
      result = resource.create_to_many_links(relationship_type, data)

      JSONAPI::OperationResult.new(result == :completed ? :no_content : :accepted)
    end

    def replace_to_many_relationship
      resource_id = params[:resource_id]
      relationship_type = params[:relationship_type].to_sym
      data = params.fetch(:data)

      resource = resource_klass.find_by_key(resource_id, context: context)
      result = resource.replace_to_many_links(relationship_type, data)

      JSONAPI::OperationResult.new(result == :completed ? :no_content : :accepted)
    end

    def remove_to_many_relationship
      resource_id = params[:resource_id]
      relationship_type = params[:relationship_type].to_sym
      associated_key = params[:associated_key]

      resource = resource_klass.find_by_key(resource_id, context: context)
      result = resource.remove_to_many_link(relationship_type, associated_key)

      JSONAPI::OperationResult.new(result == :completed ? :no_content : :accepted)
    end

    def remove_to_one_relationship
      resource_id = params[:resource_id]
      relationship_type = params[:relationship_type].to_sym

      resource = resource_klass.find_by_key(resource_id, context: context)
      result = resource.remove_to_one_link(relationship_type)

      JSONAPI::OperationResult.new(result == :completed ? :no_content : :accepted)
    end
  end
end