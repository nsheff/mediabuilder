-- pandoc.utils.make_sections exists since pandoc 2.8
if PANDOC_VERSION == nil then -- if pandoc_version < 2.1
  error("ERROR: pandoc >= 2.1 required for multi-refs filter")
else
  PANDOC_VERSION:must_be_at_least {2,8}
end

local utils = require 'pandoc.utils'
local run_json_filter = utils.run_json_filter

--- The document's metadata
local meta

-- Storage for intermediate references
local myrefs = {}
local allrefs
local split_refs = {}
local processed_entries = {}

-- Index variable for reference section (order)
local iref = 1

-- debugging function. Use it to dump a nested dict
function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end


function print_citation_keys(refs)
  for k,v in pairs(refs) do
    print(k, v.identifier)
  end
end

-- Save copied tables in `copies`, indexed by original table.
function deepcopy(orig, copies)
    copies = copies or {}
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        if copies[orig] then
            copy = copies[orig]
        else
            copy = {}
            copies[orig] = copy
            for orig_key, orig_value in next, orig, nil do
                copy[deepcopy(orig_key, copies)] = deepcopy(orig_value, copies)
            end
            setmetatable(copy, deepcopy(getmetatable(orig), copies))
        end
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

-- Find a particular identified div, recursively through block subsections
function find_rec(b, identifier)
  if not b then
    return nil
  end
    return b:find_if(function(x)
      return x.identifier==identifier
      or find_rec(x.content, identifier) end)
end

local function run_citeproc (doc)
  if PANDOC_VERSION >= '2.11' then
    local args = {'--from=json', '--to=json', '--citeproc'}
    return run_json_filter(doc, 'pandoc', args)
  else
    return run_json_filter(doc, 'pandoc-citeproc', {FORMAT, '-q'})
  end
end

-- Populate the multi-refs div with references
local function check_div (div)
  if div.identifier == "multi-refs" then
    print("Populating bibliography for multi-refs div, number: ", iref)
    -- print("split_refs", dump(split_refs[iref]))
    -- print("myrefs", dump(myrefs[iref]))
    -- div.content = myrefs[iref] # old way
    div.content = split_refs[iref]
    iref = iref+1
  end
  return div
end


local function check_doc (doc)
  local accumulated_blocks = {}
  local refspace = {}

  -- get the complete citation table, which we will split.

  doc_with_cites = run_citeproc(doc)
  allrefs = doc_with_cites.blocks:find_if(function (b)
    return b.identifier == 'refs'
  end)

  if not allrefs then
    return nil
  end
  -- print("allrefs", dump(allrefs))
  print("Total citations: ", #allrefs.content)

  local currentref = 1
  for i,el in pairs(doc.blocks) do
    table.insert(accumulated_blocks, el)
    print("Processing block " .. i)
    -- does this block have a multi-refs div?
    local has_multirefs_div = find_rec(el.content, 'multi-refs')
    local has_refs_div = find_rec(el.content, 'refs')

    if has_refs_div then
      print("has refs div!")
    end

    if has_multirefs_div then 
      -- identify the pandoc refs block
      local tmp_doc = pandoc.Pandoc(accumulated_blocks, meta)
      local new_doc = run_citeproc(tmp_doc)
      -- ab_refs: accumulated_blocks refs section. That's refs found in these blocks.
      local ab_refs = new_doc.blocks:find_if(function (b)
        return b.identifier == 'refs'
      end)

      if not ab_refs then
        print("No reference found in this block")
      else

        -- Number of citations in this section.
        print("Processing citations for multi-refs div. N citations: ", #ab_refs.content)
        -- print_citation_keys(ab_refs.content)
        table.insert(myrefs, { ab_refs })
        endval = #ab_refs.content+currentref-1
        -- These lines of code are from a dead end I took that would
        -- cut out a slice of refs from the main table; but this only worked
        -- for citation styles that ordered by reference number, not alphabetically
        -- local theserefs = {table.unpack(allrefs.content, currentref, endval)}
        -- print("theserefs", dump(theserefs))
        -- print_citation_keys(theserefs)

        -- Grab a subset of allrefs for the ones in the current accumulated blocks
        local local_refs_subset = deepcopy(allrefs)
        local_refs_subset.content = {}
        -- print("local_refs_subset", dump(local_refs_subset))
        -- local_refs_subset.content = deepcopy(theserefs)
        local i = 1
        for k,v in pairs(allrefs.content) do
          already_included = false
          for k2,v2 in pairs(ab_refs.content) do   
            if v2.identifier==v.identifier then
              -- print(k, k2, v.identifier)
              if processed_entries[v.identifier] then
                print("reference included in previous bibliography:", v.identifier)
                already_included = true
              end
              if meta['multiref_no_duplicates'] and already_included then
                print("skipping")
              else
                local_refs_subset.content[i] = v
                i = i+1
                processed_entries[v.identifier] = v.identifier
              end
            end
          end
        end
        currentref = #ab_refs.content +1
        table.insert(split_refs, {local_refs_subset})
        -- print("split_refs", dump(split_refs))
        accumulated_blocks = {}
      end
    end
  end
  return doc
end


--- Filter to the references div and bibliography header added by
--- pandoc-citeproc.
local remove_pandoc_citeproc_results = {
  Header = function (header)
    return header.identifier == 'bibliography'
      and {}
      or nil
  end,
  Div = function (div)
    return div.identifier == 'refs'
      and {}
      or nil
  end
}

local function restore_bibliography (meta)
  meta.bibliography = orig_bibliography
  return meta
end

--- Setup the document for further processing by wrapping all
--- sections in Div elements.
function set_up_document (doc)
  -- save meta for other filter functions
  meta = doc.meta
  -- print(dump(meta))
  local sections = utils.make_sections(true, nil, doc.blocks)
  return pandoc.Pandoc(sections, doc.meta)
end

return {
  -- remove result of previous pandoc-citeproc run (for backwards
  -- compatibility)
  remove_pandoc_citeproc_results,
  {Pandoc = set_up_document},
  {Pandoc = check_doc},
  {Div = check_div},
  -- {Cite = process_citations},
  -- {Blocks = Blocks},
  -- {Div = create_section_bibliography},
  -- {Div = flatten_sections, Meta = restore_bibliography}
}
