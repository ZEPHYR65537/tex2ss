local function parse(raw, name)
  local pattern = '^\\' .. name .. '{([^{}]*)}{([^{}]*)}$'
  return raw:match(pattern)
end

local function media(kind, source, label, block)
  local attr = pandoc.Attr('', {'tex2ss-media', 'tex2ss-' .. kind}, {{'data-source', source}})
  local fallback = pandoc.Link({pandoc.Str(label)}, source)
  if block then
    return pandoc.Div({pandoc.Para({fallback})}, attr)
  end
  return pandoc.Span({fallback}, attr)
end

local references = {}
local figure_number = 0
local equation_number = 0

local function index_document(document)
  return document:walk {
    Header = function(el)
      if el.identifier ~= '' then references[el.identifier] = pandoc.utils.stringify(el.content) end
      return el
    end,
    Figure = function(el)
      if el.identifier ~= '' then
        figure_number = figure_number + 1
        references[el.identifier] = tostring(figure_number)
        el.attributes['data-number'] = tostring(figure_number)
        el.classes:insert('tex2ss-numbered-figure')
      end
      return el
    end,
    Math = function(el)
      if el.mathtype ~= 'DisplayMath' then return nil end
      local label = el.text:match('\\label%s*{([^{}]+)}')
      if not label then return nil end
      equation_number = equation_number + 1
      local number = tostring(equation_number)
      references[label] = number
      el.text = el.text:gsub('\\label%s*{[^{}]+}', '', 1)
      el.text = el.text:gsub('^%s*\\begin%s*{equation%*}%s*', ''):gsub('^%s*\\begin%s*{equation}%s*', '')
      el.text = el.text:gsub('%s*\\end%s*{equation%*}%s*$', ''):gsub('%s*\\end%s*{equation}%s*$', '')
      local attr = pandoc.Attr(label, {'tex2ss-equation'}, {{'data-number', number}})
      return pandoc.Span({el, pandoc.Span({pandoc.Str('(' .. number .. ')')}, pandoc.Attr('', {'tex2ss-equation-number'}))}, attr)
    end
  }
end

local function citation_fallback(el)
  local ids = {}
  for _, citation in ipairs(el.citations) do ids[#ids + 1] = citation.id end
  el.content = pandoc.Inlines({pandoc.Str('[' .. table.concat(ids, '; ') .. ']')})
  return el
end

return {
  { Pandoc = index_document },
  {
    RawBlock = function(el)
      if el.format == 'latex' and el.text:match('^\\centering%s*$') then return {} end
      if el.format == 'latex' and el.text:match('^\\bibliographystyle%s*{[^{}]+}%s*$') then return {} end
      local source, label = parse(el.text, 'texssaudio')
      if source then return media('audio', source, label, true) end
      source, label = parse(el.text, 'texssvideo')
      if source then return media('video', source, label, true) end
      return nil
    end,
    Para = function(el)
      if #el.content ~= 1 or el.content[1].tag ~= 'RawInline' then return nil end
      local raw = el.content[1].text
      local source, label = parse(raw, 'texssaudio')
      if source then return media('audio', source, label, true) end
      source, label = parse(raw, 'texssvideo')
      if source then return media('video', source, label, true) end
      return nil
    end
  },
  {
    Cite = citation_fallback,
    RawInline = function(el)
      local target, label = parse(el.text, 'texsslink')
      if target then return pandoc.Link({pandoc.Str(label)}, target) end
      local reference = el.text:match('^\\ref%s*{([^{}]+)}$')
      if reference then
        return pandoc.Link({pandoc.Str(references[reference] or reference)}, '#' .. reference, '', pandoc.Attr('', {'tex2ss-reference'}))
      end
      reference = el.text:match('^\\eqref%s*{([^{}]+)}$')
      if reference then
        return pandoc.Link({pandoc.Str('(' .. (references[reference] or reference) .. ')')}, '#' .. reference, '', pandoc.Attr('', {'tex2ss-reference'}))
      end
      local source
      source, label = parse(el.text, 'texssaudio')
      if source then return media('audio', source, label, false) end
      source, label = parse(el.text, 'texssvideo')
      if source then return media('video', source, label, false) end
      return nil
    end
  }
}
