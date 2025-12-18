---@class vm
local vm        = require 'vm.vm'
local util      = require 'utility'
local guide     = require 'parser.guide'

local simpleSwitch

simpleSwitch = util.switch()
    : case 'goto'
    : call(function (source, pushResult)
        if source.node then
            pushResult(source.node)
        end
    end)
    : case 'super'
    : call(function (source, pushResult)
        -- Determine if super is in a call or method call context
        local parent = source.parent

        -- Check if super is being called: super()
        if parent and parent.type == 'call' then
            -- Get enclosing function and find parent constructor
            local parentFunc = guide.getParentFunction(source)
            if parentFunc then
                local setMethod = parentFunc.parent
                if setMethod and setMethod.type == 'setmethod' then
                    local classNode = setMethod.node
                    local className = guide.getKeyName(classNode)
                    if className then
                        local classType = vm.getGlobal('type', className)
                        if classType then
                            for _, set in ipairs(classType:getSets(guide.getUri(source))) do
                                if set.type == 'doc.class' and set.extends then
                                    for _, extend in ipairs(set.extends) do
                                        if extend.type == 'doc.extends.name' then
                                            local parentClassName = extend[1]
                                            local simpleName = parentClassName:match("([^.]+)$") or parentClassName

                                            -- Find parent constructor
                                            local parentType = vm.getGlobal('type', parentClassName)
                                            if parentType then
                                                vm.getClassFields(guide.getUri(source), parentType, simpleName, function(field)
                                                    if field.type == 'setmethod' and field.value then
                                                        pushResult(field.value)
                                                    end
                                                end)
                                            end
                                            return
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        else
            -- Just super keyword - jump to parent class
            local parentFunc = guide.getParentFunction(source)
            if parentFunc then
                local setMethod = parentFunc.parent
                if setMethod and setMethod.type == 'setmethod' then
                    local classNode = setMethod.node
                    local className = guide.getKeyName(classNode)
                    if className then
                        local classType = vm.getGlobal('type', className)
                        if classType then
                            for _, set in ipairs(classType:getSets(guide.getUri(source))) do
                                if set.type == 'doc.class' and set.extends then
                                    for _, extend in ipairs(set.extends) do
                                        if extend.type == 'doc.extends.name' then
                                            pushResult(extend)
                                            return
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    : case 'doc.cast.name'
    : call(function (source, pushResult)
        local loc = guide.getLocal(source, source[1], source.start)
        if loc then
            pushResult(loc)
        end
    end)
    : case 'doc.field'
    : call(function (source, pushResult)
        pushResult(source)
    end)
    : case 'getlocal'
    : case 'getglobal'
    : call(function (source, pushResult)
        -- Check if this is part of a Class() call
        local parent = source.parent
        if parent and parent.type == 'call' and parent.node == source then
            -- This is the function being called
            local className = source[1]
            if className then
                local classType = vm.getGlobal('type', className)
                if classType then
                    -- Find constructor method
                    local foundConstructor = false
                    vm.getClassFields(guide.getUri(source), classType, className, function(field)
                        if field.type == 'setmethod' and field.value then
                            pushResult(field.value)
                            foundConstructor = true
                        end
                    end)
                    if foundConstructor then
                        return  -- Don't fall through to variable definition
                    end
                end
            end
        end

        -- Default: use normal variable definition search
        -- (will be handled by searchByNode or other mechanisms)
    end)
    : case 'call'
    : call(function (source, pushResult)
        -- Fallback for call node itself
        if source.node then
            pushResult(source.node)
        end
    end)

---@param source  parser.object
---@param pushResult fun(src: parser.object)
local function searchBySimple(source, pushResult)
    simpleSwitch(source.type, source, pushResult)
end

---@param source  parser.object
---@param pushResult fun(src: parser.object)
local function searchByLocalID(source, pushResult)
    local idSources = vm.getVariableSets(source)
    if not idSources then
        return
    end
    for _, src in ipairs(idSources) do
        pushResult(src)
    end
end

local function searchByNode(source, pushResult)
    local node = vm.compileNode(source)
    local suri = guide.getUri(source)
    for n in node:eachObject() do
        if n.type == 'global' then
            for _, set in ipairs(n:getSets(suri)) do
                pushResult(set)
            end
        else
            pushResult(n)
        end
    end
end

---@param source parser.object
---@return       parser.object[]
function vm.getDefs(source)
    local results = {}
    local mark    = {}
    local skipDefaultSearch = false  -- Flag to skip default searches

    local hasLocal
    local function pushResult(src)
        if src.type == 'local' then
            if hasLocal then
                return
            end
            hasLocal = true
            if  source.type ~= 'local'
            and source.type ~= 'getlocal'
            and source.type ~= 'setlocal'
            and source.type ~= 'doc.cast.name' then
                return
            end
        end
        if not mark[src] then
            mark[src] = true
            if guide.isAssign(src)
            or guide.isLiteral(src) then
                results[#results+1] = src
            end
        end
    end

    -- Custom wrapper to set skip flag
    local function pushResultWithSkip(src)
        pushResult(src)
        skipDefaultSearch = true
    end

    -- For getlocal/getglobal in call context, use special pushResult
    if (source.type == 'getlocal' or source.type == 'getglobal')
       and source.parent and source.parent.type == 'call' and source.parent.node == source then
        searchBySimple(source, pushResultWithSkip)
        if not skipDefaultSearch then
            searchByLocalID(source, pushResult)
            vm.compileByNodeChain(source, pushResult)
            searchByNode(source, pushResult)
        end
    else
        searchBySimple(source, pushResult)
        searchByLocalID(source, pushResult)
        vm.compileByNodeChain(source, pushResult)
        searchByNode(source, pushResult)
    end

    return results
end

local HAS_DEF_ERR = false  -- the error object for comparing
local function checkHasDef(checkFunc, source, pushResult)
    local _, err = pcall(checkFunc, source, pushResult)
    return err == HAS_DEF_ERR
end

---@param source parser.object
function vm.hasDef(source)
    local mark = {}
    local hasLocal
    local function pushResult(src)
        if src.type == 'local' then
            if hasLocal then
                return
            end
            hasLocal = true
            if  source.type ~= 'local'
            and source.type ~= 'getlocal'
            and source.type ~= 'setlocal'
            and source.type ~= 'doc.cast.name' then
                return
            end
        end
        if not mark[src] then
            mark[src] = true
            if guide.isAssign(src)
            or guide.isLiteral(src) then
                -- break out on 1st result using error() with a unique error object
                error(HAS_DEF_ERR)
            end
        end
    end

    return checkHasDef(searchBySimple, source, pushResult)
        or checkHasDef(searchByLocalID, source, pushResult)
        or checkHasDef(vm.compileByNodeChain, source, pushResult)
        or checkHasDef(searchByNode, source, pushResult)
end
