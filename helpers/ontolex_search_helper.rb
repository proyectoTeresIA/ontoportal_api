module OntolexSearchHelper
  # Calculates a search relevance score for an item based on how well its label matches the query.
  #
  # Priority order:
  # 1. Exact match (score: 0)
  # 2. Starts with query (score: 1)
  # 3. Contains query as a word boundary (e.g., "palabra" matches "mi_palabra") (score: 2)
  # 4. Contains query elsewhere - position-based score (score: 3 + position/1000)
  def search_relevance_score(label_lower, search_query)
    return Float::INFINITY unless label_lower.include?(search_query)
    
    return 0 if label_lower == search_query
    return 1 if label_lower.start_with?(search_query)
    
    word_boundary_pattern = /(?:^|[\s_\-\.])#{Regexp.escape(search_query)}/
    if word_boundary_pattern.match?(label_lower)
      return 2
    end
    
    position = label_lower.index(search_query)
    return 3 + (position.to_f / 1000) if position
    
    Float::INFINITY
  end

  # Filters and sorts items based on search query relevance.
  def filter_and_sort_by_relevance(items_with_labels, search_query)
    if search_query.nil? || search_query.empty?
      # If no search query, sort alphabetically
      items_with_labels.sort_by { |item| item[:label_lower] }
    else
      # Filter to items that contain the search query
      matching_items = items_with_labels.select { |item| item[:label_lower].include?(search_query) }
      
      # Sort by relevance score first, then alphabetically
      matching_items.sort_by do |item|
        score = search_relevance_score(item[:label_lower], search_query)
        [score, item[:label_lower]]
      end
    end
  end
end
