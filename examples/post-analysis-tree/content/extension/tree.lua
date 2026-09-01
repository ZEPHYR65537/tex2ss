function pre_generator(context)
  local headings = {}
  local extras = {}
  for _, export in ipairs(context.analysis_exports) do
    headings[export.document] = export.value.heading
    if export.document ~= "chapter" and export.document ~= "chapter/topic" then
      extras[#extras + 1] = pandoc.Plain({ pandoc.Str(export.value.heading) })
    end
  end

  local child = assert(headings["chapter"])
  local grandchild = assert(headings["chapter/topic"])
  local items = {
    {
      pandoc.Plain({ pandoc.Str(child) }),
      pandoc.BulletList({
        { pandoc.Plain({ pandoc.Str(grandchild) }) }
      })
    }
  }
  for _, extra in ipairs(extras) do
    items[#items + 1] = { extra }
  end
  local tree = pandoc.BulletList(items)

  return {
    fragments = {
      tree = {
        type = "pandoc_blocks",
        blocks = pandoc.Blocks({ tree })
      }
    }
  }
end
