local files = require 'files'
local guide = require 'parser.guide'
local vm    = require 'vm.vm'
local lang  = require 'language'

---@param uri uri
---@param callback fun(result: table)
return function (uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    -- Find all method definitions
    guide.eachSourceType(state.ast, 'setmethod', function (source)
        local methodName = guide.getKeyName(source.method)
        if not methodName then
            return
        end

        -- Get the class this method belongs to
        local classNode = source.node
        if not classNode then
            return
        end

        local className = guide.getKeyName(classNode)
        if not className then
            return
        end

        -- Check if this is a constructor (skip validation)
        local simpleName = className:match("([^.]+)$") or className
        if methodName == simpleName then
            return  -- Don't validate constructors
        end

        -- Get class type and check for parent
        local classType = vm.getGlobal('type', className)
        if not classType then
            return
        end

        -- Find parent class
        for _, set in ipairs(classType:getSets(uri)) do
            if set.type == 'doc.class' and set.extends then
                for _, extend in ipairs(set.extends) do
                    if extend.type == 'doc.extends.name' then
                        local parentClassName = extend[1]

                        -- Find parent method with same name
                        local parentType = vm.getGlobal('type', parentClassName)
                        if parentType then
                            vm.getClassFields(uri, parentType, methodName, function(parentMethod)
                                if parentMethod.type ~= 'setmethod' then
                                    return
                                end

                                -- Get function signatures
                                local childFunc = source.value
                                local parentFunc = parentMethod.value

                                if not childFunc or not parentFunc then
                                    return
                                end

                                -- Check parameter count (excluding 'self')
                                local childParams = childFunc.args or {}
                                local parentParams = parentFunc.args or {}

                                -- Count non-self parameters
                                local childCount = 0
                                for _, param in ipairs(childParams) do
                                    if param[1] ~= 'self' then
                                        childCount = childCount + 1
                                    end
                                end

                                local parentCount = 0
                                for _, param in ipairs(parentParams) do
                                    if param[1] ~= 'self' then
                                        parentCount = parentCount + 1
                                    end
                                end

                                if childCount ~= parentCount then
                                    callback {
                                        start   = source.method.start,
                                        finish  = source.method.finish,
                                        message = lang.script('DIAG_OVERRIDE_PARAM_COUNT', methodName, parentCount, childCount)
                                    }
                                end

                                -- Check parameter types (skip 'self')
                                for i, childParam in ipairs(childParams) do
                                    -- Skip 'self' parameter
                                    if childParam[1] == 'self' then
                                        goto NEXT_PARAM
                                    end

                                    local parentParam = parentParams[i]
                                    if parentParam then
                                        -- Skip if parent param is also 'self'
                                        if parentParam[1] == 'self' then
                                            goto NEXT_PARAM
                                        end

                                        local childType = vm.getInfer(childParam):view(uri)
                                        local parentType = vm.getInfer(parentParam):view(uri)

                                        if childType ~= parentType and childType ~= 'unknown' and parentType ~= 'unknown' then
                                            callback {
                                                start   = childParam.start,
                                                finish  = childParam.finish,
                                                message = lang.script('DIAG_OVERRIDE_PARAM_TYPE', childParam[1], parentType, childType)
                                            }
                                        end
                                    end

                                    ::NEXT_PARAM::
                                end

                                -- Check return type
                                local childReturns = childFunc.returns or {}
                                local parentReturns = parentFunc.returns or {}

                                if #childReturns > 0 and #parentReturns > 0 then
                                    local childReturn = childReturns[1] and childReturns[1][1]
                                    local parentReturn = parentReturns[1] and parentReturns[1][1]

                                    if childReturn and parentReturn then
                                        local childRetType = vm.getInfer(childReturn):view(uri)
                                        local parentRetType = vm.getInfer(parentReturn):view(uri)

                                        if childRetType ~= parentRetType and childRetType ~= 'unknown' and parentRetType ~= 'unknown' then
                                            callback {
                                                start   = source.method.start,
                                                finish  = source.method.finish,
                                                message = lang.script('DIAG_OVERRIDE_RETURN_TYPE', methodName, parentRetType, childRetType)
                                            }
                                        end
                                    end
                                end
                            end)
                        end

                        return  -- Only check first parent
                    end
                end
            end
        end
    end)
end
