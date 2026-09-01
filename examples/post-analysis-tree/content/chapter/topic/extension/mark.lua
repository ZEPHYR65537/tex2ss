function Header(header)
  header.content:insert(pandoc.Space())
  header.content:insert(pandoc.Str("filtered"))
  return header
end

