function post_analyzer(document, context)
  assert(context.export.namespace == "example.outline")
  assert(context.export.schema_version == 1)

  for _, block in ipairs(document.blocks) do
    if block.t == "Header" then
      return { heading = pandoc.utils.stringify(block) }
    end
  end

  error("heading not found")
end

