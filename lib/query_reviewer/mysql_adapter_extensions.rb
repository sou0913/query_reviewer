module QueryReviewer
  module MysqlAdapterExtensions
    def self.included(base)
      base.alias_method :select_without_review, :select
      base.alias_method :select, :select_with_review
      base.alias_method :update_without_review, :update
      base.alias_method :update, :update_with_review
      base.alias_method :insert_without_review, :insert
      base.alias_method :insert, :insert_with_review
      base.alias_method :delete_without_review, :delete
      base.alias_method :delete, :delete_with_review 
    end

    def update_with_review(sql, *args)
      t1 = Time.now
      result = update_without_review(sql, *args)
      t2 = Time.now

      create_or_add_query_to_query_reviewer!(sql, nil, t2 - t1, nil, "UPDATE", result)

      result
    end

    def insert_with_review(arg1, *otherargs)
      # arg1 is sql for rails 3.0 & 3.1, arel for newer versions

      rails30 = Rails::VERSION::MAJOR == 3 && [0,1].include?(Rails::VERSION::MINOR)
      sql = arg1 if rails30
      bind_params = otherargs[4] || [] unless rails30

      t1 = Time.now
      result = insert_without_review(arg1, *otherargs)
      t2 = Time.now

      sql = to_sql(arg1, bind_params) unless rails30
      create_or_add_query_to_query_reviewer!(sql, nil, t2 - t1, nil, "INSERT")

      result
    end

    def delete_with_review(sql, *args)
      t1 = Time.now
      result = delete_without_review(sql, *args)
      t2 = Time.now

      create_or_add_query_to_query_reviewer!(sql, nil, t2 - t1, nil, "DELETE", result)

      result
    end

    def select_with_review(sql, *args)
      return select_without_review(sql, *args) unless query_reviewer_enabled?

      sql.gsub!(/^SELECT /i, "SELECT SQL_NO_CACHE ") if QueryReviewer::CONFIGURATION["disable_sql_cache"]
      QueryReviewer.safe_log { execute("SET PROFILING=1") } if QueryReviewer::CONFIGURATION["profiling"]
      t1 = Time.now
      query_results = select_without_review(sql, *args)
      t2 = Time.now

      if @logger && query_reviewer_enabled? && sql =~ /^select/i
        use_profiling = QueryReviewer::CONFIGURATION["profiling"]
        use_profiling &&= (t2 - t1) >= QueryReviewer::CONFIGURATION["warn_duration_threshold"].to_f / 2.0 if QueryReviewer::CONFIGURATION["production_data"]

        if use_profiling
          t5 = Time.now
          QueryReviewer.safe_log { execute("SET PROFILING=1") }
          t3 = Time.now
          select_without_review(sql, *args)
          t4 = Time.now
          profile = QueryReviewer.safe_log { select_without_review("SHOW PROFILE ALL", *args) }
          QueryReviewer.safe_log { execute("SET PROFILING=0") }
          t6 = Time.now
          Thread.current["queries"].overhead_time += t6 - t5
        else
          profile = nil
        end

        cols = QueryReviewer.safe_log do
          select_without_review("explain #{sql}", *args)
        end

        duration = t3 ? [t2 - t1, t4 - t3].min : t2 - t1
        create_or_add_query_to_query_reviewer!(sql, cols, duration, profile)

        #@logger.debug(format_log_entry("Analyzing #{name}\n", query.to_table)) if @logger.level <= Logger::INFO
      end
      query_results
    end

    def query_reviewer_enabled?
      Thread.current["queries"] && Thread.current["queries"].respond_to?(:find_or_create_sql_query) && Thread.current["query_reviewer_enabled"]
    end

    def create_or_add_query_to_query_reviewer!(sql, cols, run_time, profile, command = "SELECT", affected_rows = 1)
      if query_reviewer_enabled?
        t1 = Time.now
        Thread.current["queries"].find_or_create_sql_query(sql, cols, run_time, profile, command, affected_rows)
        t2 = Time.now
        Thread.current["queries"].overhead_time += t2 - t1
      end
    end
  end
end
