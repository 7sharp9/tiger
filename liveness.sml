signature LIVENESS = 
sig
  datatype igraph =
           IGRAPH of {graph: Graph.graph,
                      tnode: Temp.temp -> Graph.node,
                      gtemp: Graph.node -> Temp.temp,
                      moves: (Graph.node * Graph.node) list}

  val interferenceGraph : 
      Flow.flowgraph -> igraph * (Graph.node -> Temp.temp list)

  val show : TextIO.outstream * igraph -> unit

end

structure TempKey : ORD_KEY = 
struct
type ord_key = Temp.temp
fun compare (t1,t2) = 
    String.compare(Temp.makestring t1,Temp.makestring t2)
end

structure Liveness :> LIVENESS = 
struct 

structure G = Graph
structure GT = Graph.Table
structure S = ListSetFn(TempKey)
structure T = Temp
structure TT = Temp.Table
structure Frame = MipsFrame

datatype igraph =
         IGRAPH of {graph: G.graph,
                    tnode: T.temp -> G.node,
                    gtemp: G.node -> T.temp,
                    moves: (G.node * G.node) list}
                   
type liveSet = S.set
type liveMap = liveSet GT.table
type tempEdge = {src:Temp.temp,dst:Temp.temp}

                                                   
fun show (output,IGRAPH{graph,tnode,gtemp,moves}) = 
    let
	val node2str = Frame.temp_name o gtemp
	fun process1 node =
	    TextIO.output(output,
			  ((node2str node) ^ " -> {" ^
			   (String.concatWith 
				", "
				(map node2str (Graph.adj node))) ^ "}\n"))
    in app process1 (Graph.nodes graph) end

    
fun interferenceGraph
        (flowgraph as Flow.FGRAPH{control,def,use,ismove} ) = 
  let 
    val igraph = G.newGraph ()
                 
    val allnodes = G.nodes control
                   
    fun look (table,key) = valOf(GT.look(table,key))

    (* compute live-in sets for all nodes on graph, using current
     * live-out sets information. Then, we use the live-in sets 
     * information to compute live-out sets *)
    fun compute_insets (liveout_map:liveMap) : liveMap = 
      let 
        fun f n = 
          let 
            val uset = S.addList(S.empty,look(use,n))
            val dset = S.addList(S.empty,look(def,n))
          in
            S.union(uset,S.difference(look(liveout_map,n),dset))
          end
      in foldl (fn (n,m) => GT.enter(m, n, f n)) GT.empty allnodes
      end


    (* compute outset for a particular node *)
    fun compute_outset (livein_map,node) : liveSet =
        foldl (fn (n,s) => S.union(look(livein_map,n),s))
              S.empty (G.succ(node))


    fun set2str set = "{" ^ (String.concatWith ", "
                             (map Temp.makestring (S.listItems set))) ^ "}"

    fun println s = print(s ^ "\n")

    (* iteratively compute liveSet, until reaches a fix point *)
    fun iter (liveout_map:liveMap) : liveMap = 
      let 
        val changed = ref false
        val livein_map = compute_insets liveout_map
        val new_liveout_map = 
            foldl
                (fn (x,m) =>
                    let val newset = compute_outset(livein_map,x) in
                      if S.isEmpty(S.difference(newset, look(m,x)))
                      then () else changed := true;
                      GT.enter(m,x,newset)
                    end
                ) liveout_map (G.nodes control)
      in if !changed then iter new_liveout_map else new_liveout_map end
      
    val liveout = 
        iter (foldl (fn (n,tb) => GT.enter(tb,n,S.empty)) GT.empty allnodes)
  in
    (* now for each node n in the flow graph, suppose
     * there is a newly define temp d, and temporaries
     * t1, ..., tn are in liveout set of node n. Then,
     * we add edge (d,t1), ..., (d,tn) to the igraph.
     * Mappings between temps and igraph nodes are also recorded. *)
    let

      fun find_edges node : tempEdge list = 
        let
          val defset = look(def,node)
          val outset = S.listItems(look(liveout,node))
          fun f t = foldl (fn (t',l) => {src=t,dst=t'}::l) nil outset
        in foldl (fn (t,l) => (f t) @ l) nil defset end
        
      val all_edges : tempEdge list = 
          foldl (fn (n,l) => find_edges(n) @ l) nil allnodes
          
      fun make_table tlist = 
        foldl
          (fn (t,(t2n,n2t)) => 
            case TT.look(t2n,t) of
              SOME(n) => (t2n,n2t)
            | NONE =>
              let val n = Graph.newNode(igraph) in
                (TT.enter(t2n,t,n),GT.enter(n2t,n,t)) end
          ) (TT.empty,GT.empty) tlist
        
      val (temp2node,node2temp) = 
        make_table ((map #src all_edges) @ (map #dst all_edges))
          
      fun looktemp (t: T.temp) : G.node =
        case TT.look(temp2node,t) of SOME(n) => n
                                                
      fun looknode (n:G.node) : T.temp =
        case GT.look(node2temp,n) of SOME(t) => t
                                                
      fun lookliveout (n:G.node) : T.temp list =
        case GT.look(liveout,n) of SOME(s) => S.listItems(s)

      val allmoves = 
        foldl
          (fn (n,l) =>
            case GT.look(ismove,n) of
              SOME(b) => 
              if b then 
                let val [src] = look(use,n)
                    val [dst] = look(def,n) in
                  (looktemp(src),looktemp(dst)) :: l
                end
              else l
          ) nil allnodes
                                                  
    in app (fn {src,dst} => 
               G.mk_edge{from=looktemp(src),to=looktemp(dst)})
           all_edges;
       (IGRAPH{graph=igraph,tnode=looktemp,gtemp=looknode,moves=allmoves},
        lookliveout)
    end
  end
end
