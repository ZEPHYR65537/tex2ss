local tex2ss = require "tex2ss"

local function escape_latex(text)
  return text:gsub("([%%#$&_{}])", "\\\\%1")
end

return {
  analyze = function(document, _ctx)
    local headings = {}
    document:walk {
      Header = function(header)
        headings[#headings + 1] = pandoc.utils.stringify(header.content)
      end
    }
    return { heading = headings[1] or "Untitled" }
  end,

  generate = function(ctx)
    local lines = { "\\begin{itemize}" }
    for _, result in ipairs(ctx.analysis) do
      local label = result.document .. ": " .. result.value.heading
      lines[#lines + 1] = "\\item " .. escape_latex(label)
    end
    lines[#lines + 1] = "\\end{itemize}"
    return { tree = tex2ss.latex(table.concat(lines, "\n")) }
  end
}
