# This file is a part of Julia. License is MIT: https://julialang.org/license

if !isdefined(@__MODULE__, Symbol("@verify_error"))
    macro verify_error(arg)
        arg isa String && return esc(:(print && println(stderr, $arg)))
        (arg isa Expr && arg.head === :string) || error("verify_error macro expected a string expression")
        pushfirst!(arg.args, GlobalRef(Core, :stderr))
        pushfirst!(arg.args, :println)
        arg.head = :call
        return esc(arg)
    end
end

function check_op(ir::IRCode, domtree::DomTree, @nospecialize(op), use_bb::Int, use_idx::Int, print::Bool, isforeigncall::Bool, arg_idx::Int)
    if isa(op, SSAValue)
        if op.id > length(ir.stmts)
            def_bb = block_for_inst(ir.cfg, ir.new_nodes.info[op.id - length(ir.stmts)].pos)
        else
            def_bb = block_for_inst(ir.cfg, op.id)
        end
        if (def_bb == use_bb)
            if op.id > length(ir.stmts)
                @assert ir.new_nodes.info[op.id - length(ir.stmts)].pos <= use_idx
            else
                if op.id >= use_idx
                    @verify_error "Def ($(op.id)) does not dominate use ($(use_idx)) in same BB"
                    error("")
                end
            end
        else
            if !dominates(domtree, def_bb, use_bb) && !(bb_unreachable(domtree, def_bb) && bb_unreachable(domtree, use_bb))
                # At the moment, we allow GC preserve tokens outside the standard domination notion
                #@Base.show ir
                @verify_error "Basic Block $def_bb does not dominate block $use_bb (tried to use value $(op.id))"
                error("")
            end
        end
    elseif isa(op, GlobalRef)
        if !isdefined(op.mod, op.name) || !isconst(op.mod, op.name)
            @verify_error "Unbound GlobalRef not allowed in value position"
            error("")
        end
    elseif isa(op, Expr)
        # Only Expr(:boundscheck) is allowed in value position
        if isforeigncall && arg_idx == 1 && op.head === :call
            # Allow a tuple in symbol position for foreigncall - this isn't actually
            # a real call - it's interpreted in global scope by codegen. However,
            # we do need to keep this a real use, because it could also be a pointer.
        elseif op.head !== :boundscheck
            @verify_error "Expr not allowed in value position"
            error("")
        end
    elseif isa(op, Union{OldSSAValue, NewSSAValue})
        #@Base.show ir
        @verify_error "Left over SSA marker"
        error("")
    elseif isa(op, Union{SlotNumber, TypedSlot})
        @verify_error "Left over slot detected in converted IR"
        error("")
    end
end

function count_int(val::Int, arr::Vector{Int})
    n = 0
    for x in arr
        if x === val
            n += 1
        end
    end
    n
end

function verify_ir(ir::IRCode, print::Bool=true)
    # For now require compact IR
    # @assert isempty(ir.new_nodes)
    # Verify CFG
    last_end = 0
    # Verify statements
    domtree = construct_domtree(ir.cfg.blocks)
    for (idx, block) in pairs(ir.cfg.blocks)
        if first(block.stmts) != last_end + 1
            #ranges = [(idx,first(bb.stmts),last(bb.stmts)) for (idx, bb) in pairs(ir.cfg.blocks)]
            @verify_error "First statement of BB $idx ($(first(block.stmts))) does not match end of previous ($last_end)"
            error("")
        end
        last_end = last(block.stmts)
        terminator = ir.stmts[last_end][:inst]

        bb_unreachable(domtree, idx) && continue
        for p in block.preds
            p == 0 && continue
            c = count_int(idx, ir.cfg.blocks[p].succs)
            if c == 0
                @verify_error "Predecessor $p of block $idx not in successor list"
                error("")
            elseif c == 2
                if count_int(p, block.preds) != 2
                    @verify_error "Double edge from $p to $idx not correctly accounted"
                    error("")
                end
            end
        end
        if isa(terminator, ReturnNode)
            if !isempty(block.succs)
                @verify_error "Block $idx ends in return or unreachable, but has successors"
                error("")
            end
        elseif isa(terminator, GotoNode)
            if length(block.succs) != 1 || block.succs[1] != terminator.label
                @verify_error "Block $idx successors ($(block.succs)), does not match GotoNode terminator"
                error("")
            end
        elseif isa(terminator, GotoIfNot)
            if terminator.dest == idx + 1
                @verify_error "Block $idx terminator forms a double edge to block $(idx+1)"
                error("")
            end
            if length(block.succs) != 2 || (block.succs != [terminator.dest, idx+1] && block.succs != [idx+1, terminator.dest])
                @verify_error "Block $idx successors ($(block.succs)), does not match GotoIfNot terminator"
                error("")
            end
        elseif isexpr(terminator, :enter)
            @label enter_check
            if length(block.succs) != 2 || (block.succs != Int[terminator.args[1], idx+1] && block.succs != Int[idx+1, terminator.args[1]])
                @verify_error "Block $idx successors ($(block.succs)), does not match :enter terminator"
                error("")
            end
        else
            if length(block.succs) != 1 || block.succs[1] != idx + 1
                # As a special case, we allow extra statements in the BB of an :enter
                # statement, until we can do proper CFG manipulations during compaction.
                for idx in first(block.stmts):last(block.stmts)
                    stmt = ir.stmts[idx][:inst]
                    if isexpr(stmt, :enter)
                        terminator = stmt
                        @goto enter_check
                    end
                    isa(stmt, PhiNode) || break
                end
                @verify_error "Block $idx successors ($(block.succs)), does not match fall-through terminator ($terminator)"
                error("")
            end
        end
        for s in block.succs
            if !(idx in ir.cfg.blocks[s].preds)
                #@Base.show ir.cfg
                #@Base.show ir
                #@Base.show ir.argtypes
                @verify_error "Successor $s of block $idx not in predecessor list"
                error("")
            end
        end
    end
    for (bb, idx) in bbidxiter(ir)
        # We allow invalid IR in dead code to avoid passes having to detect when
        # they're generating dead code.
        bb_unreachable(domtree, bb) && continue
        stmt = ir.stmts[idx][:inst]
        stmt === nothing && continue
        if isa(stmt, PhiNode)
            @assert length(stmt.edges) == length(stmt.values)
            for i = 1:length(stmt.edges)
                edge = stmt.edges[i]
                for j = (i+1):length(stmt.edges)
                    edge′ = stmt.edges[j]
                    if edge == edge′
                        # TODO: Move `unique` to Core.Compiler. For now we assume the predecessor list is
                        @verify_error "Edge list φ node $idx in bb $bb not unique (double edge?)"
                        error("")
                    end
                end
                if !(edge == 0 && bb == 1) && !(edge in ir.cfg.blocks[bb].preds)
                    #@Base.show ir.argtypes
                    #@Base.show ir
                    @verify_error "Edge $edge of φ node $idx not in predecessor list"
                    error("")
                end
                edge == 0 && continue
                isassigned(stmt.values, i) || continue
                val = stmt.values[i]
                phiT = ir.stmts[idx][:type]
                if isa(val, SSAValue)
                    if !(types(ir)[val] ⊑ phiT)
                        #@verify_error """
                        #    PhiNode $idx, has operand $(val.id), whose type is not a sub lattice element.
                        #    PhiNode type was $phiT
                        #    Value type was $(ir.stmts[val.id][:type])
                        #"""
                        #error("")
                    end
                end
                check_op(ir, domtree, val, Int(edge), last(ir.cfg.blocks[stmt.edges[i]].stmts)+1, print, false, i)
            end
        elseif isa(stmt, PhiCNode)
            for i = 1:length(stmt.values)
                val = stmt.values[i]
                if !isa(val, SSAValue)
                    @verify_error "Operand $i of PhiC node $idx must be an SSA Value."
                    error("")
                end
                if !isa(ir[val][:inst], UpsilonNode)
                    @verify_error "Operand $i of PhiC node $idx must reference an Upsilon node."
                    error("")
                end
            end
        else
            if isa(stmt, Expr) || isa(stmt, ReturnNode) # TODO: make sure everything has line info
                if !(stmt isa ReturnNode && !isdefined(stmt, :val)) # not actually a return node, but an unreachable marker
                    if ir.stmts[idx][:line] <= 0
                        #@verify_error "Missing line number information for statement $idx of $ir"
                    end
                end
            end
            isforeigncall = false
            if isa(stmt, Expr)
                if stmt.head === :(=)
                    if stmt.args[1] isa SSAValue
                        @verify_error "SSAValue as assignment LHS"
                        error("")
                    end
                    if stmt.args[2] isa GlobalRef
                        # undefined GlobalRef as assignment RHS is OK
                        continue
                    end
                elseif stmt.head === :gc_preserve_end
                    # We allow gc_preserve_end tokens to span across try/catch
                    # blocks, which isn't allowed for regular SSA values, so
                    # we skip the validation below.
                    continue
                elseif stmt.head === :foreigncall
                    isforeigncall = true
                elseif stmt.head === :isdefined && length(stmt.args) == 1 &&
                        (stmt.args[1] isa GlobalRef || (stmt.args[1] isa Expr && stmt.args[1].head === :static_parameter))
                    # a GlobalRef or static_parameter isdefined check does not evaluate its argument
                    continue
                end
            end
            n = 1
            for op in userefs(stmt)
                op = op[]
                check_op(ir, domtree, op, bb, idx, print, isforeigncall, n)
                n += 1
            end
        end
    end
end

function verify_linetable(linetable::Vector{LineInfoNode}, print::Bool=true)
    for i in 1:length(linetable)
        line = linetable[i]
        if i <= line.inlined_at
            @verify_error "Misordered linetable"
            error("")
        end
    end
end
