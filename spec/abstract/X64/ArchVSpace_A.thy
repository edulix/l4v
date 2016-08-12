(*
 * Copyright 2014, General Dynamics C4 Systems
 *
 * This software may be distributed and modified according to the terms of
 * the GNU General Public License version 2. Note that NO WARRANTY is provided.
 * See "LICENSE_GPLv2.txt" for details.
 *
 * @TAG(GD_GPL)
 *)

(*
Higher level functions for manipulating virtual address spaces
*)

chapter "x64 VSpace Functions"

theory ArchVSpace_A
imports "../Retype_A"
begin

context Arch begin global_naming X64_A
text {*
  These attributes are always set to @{const False} when pages are mapped.
*}
definition
  "attr_mask = {Global,Dirty,PTAttr Accessed,PTAttr ExecuteDisable}"

text {* Save the set of entries that would be inserted into a page table or
page directory to map various different sizes of frame at a given virtual
address. *}
primrec create_mapping_entries ::
  "paddr \<Rightarrow> vspace_ref \<Rightarrow> vmpage_size \<Rightarrow> vm_rights \<Rightarrow> frame_attrs \<Rightarrow> obj_ref \<Rightarrow>
  (vm_page_entry * obj_ref,'z::state_ext) se_monad"
where
  "create_mapping_entries base vptr X64SmallPage vm_rights attrib pd =
  doE
    p \<leftarrow> lookup_error_on_failure False $ lookup_pt_slot pd vptr;
    returnOk $ (VMPTE (SmallPagePTE base (attrib - attr_mask) vm_rights), p)
  odE"

| "create_mapping_entries base vptr X64LargePage vm_rights attrib pdpt =
  doE
    p \<leftarrow> lookup_error_on_failure False $ lookup_pd_slot pdpt vptr;
    returnOk $ (VMPDE (LargePagePDE base (attrib - attr_mask) vm_rights), p)
  odE"

| "create_mapping_entries base vptr X64HugePage vm_rights attrib pml4 =
  doE
    p \<leftarrow> lookup_error_on_failure False $ lookup_pdpt_slot pml4 vptr;
    returnOk $ (VMPDPTE (HugePagePDPTE base (attrib - attr_mask) vm_rights), p)
  odE"


text {* This function checks that given entries are either invalid entries (for unmapping)
or replace invalid entries (for mapping). *}
fun ensure_safe_mapping ::
  "(vm_page_entry * obj_ref) \<Rightarrow> (unit,'z::state_ext) se_monad"
where
"ensure_safe_mapping (VMPTE InvalidPTE, _) = returnOk ()"
|
"ensure_safe_mapping (VMPDE InvalidPDE, _) = returnOk ()"
|
"ensure_safe_mapping (VMPDPTE InvalidPDPTE, _) = returnOk ()"
|
"ensure_safe_mapping (VMPTE (SmallPagePTE _ _ _), pt_slot) =
    doE
        pte \<leftarrow> liftE $ get_pte pt_slot;
        (case pte of
              InvalidPTE \<Rightarrow> returnOk ()
            | _ \<Rightarrow> throwError DeleteFirst)
    odE"
|
"ensure_safe_mapping (VMPDE (LargePagePDE _ _ _), pd_slot) =
    doE
        pde \<leftarrow> liftE $ get_pde pd_slot;
        (case pde of
              InvalidPDE \<Rightarrow> returnOk ()
            | _ \<Rightarrow> throwError DeleteFirst)
    odE"
|
"ensure_safe_mapping (VMPDPTE (HugePagePDPTE _ _ _), pdpt_slot) =
    doE
        pdpt \<leftarrow> liftE $ get_pdpte pdpt_slot;
        (case pdpt of
              InvalidPDPTE \<Rightarrow> returnOk ()
            | _ \<Rightarrow> throwError DeleteFirst)
    odE"
|
"ensure_safe_mapping (VMPDE (PageTablePDE _ _ _), _) = fail"
|
"ensure_safe_mapping (VMPDPTE (PageDirectoryPDPTE _ _ _), _) = fail"

text {* Look up a thread's IPC buffer and check that the thread has the right
authority to read or (in the receiver case) write to it. *}
definition
lookup_ipc_buffer :: "bool \<Rightarrow> obj_ref \<Rightarrow> (obj_ref option,'z::state_ext) s_monad" where
"lookup_ipc_buffer is_receiver thread \<equiv> do
    buffer_ptr \<leftarrow> thread_get tcb_ipc_buffer thread;
    buffer_frame_slot \<leftarrow> return (thread, tcb_cnode_index 4);
    buffer_cap \<leftarrow> get_cap buffer_frame_slot;
    (case buffer_cap of
      ArchObjectCap (PageCap p R _ vms _) \<Rightarrow>
        if vm_read_write \<subseteq> R \<or> vm_read_only \<subseteq> R \<and> \<not>is_receiver
        then return $ Some $ p + (buffer_ptr && mask (pageBitsForSize vms))
        else return None
    | _ \<Rightarrow> return None)
od"

text {* Locate the page directory associated with a given virtual ASID. *}
definition
find_vspace_for_asid :: "asid \<Rightarrow> (obj_ref,'z::state_ext) lf_monad" where
"find_vspace_for_asid asid \<equiv> doE
    assertE (asid > 0);
    asid_table \<leftarrow> liftE $ gets (x64_asid_table \<circ> arch_state);
    pool_ptr \<leftarrow> returnOk (asid_table (asid_high_bits_of asid));
    pool \<leftarrow> (case pool_ptr of
               Some ptr \<Rightarrow> liftE $ get_asid_pool ptr
             | None \<Rightarrow> throwError InvalidRoot);
    pml4 \<leftarrow> returnOk (pool (ucast asid));
    (case pml4 of
          Some ptr \<Rightarrow> returnOk ptr
        | None \<Rightarrow> throwError InvalidRoot)
odE"


text {* Locate the page directory and check that this process succeeds and
returns a pointer to a real page directory. *}
definition
find_vspace_for_asid_assert :: "asid \<Rightarrow> (obj_ref,'z::state_ext) s_monad" where
"find_vspace_for_asid_assert asid \<equiv> do
   pml4 \<leftarrow> find_vspace_for_asid asid <catch> K fail;
   get_pml4 pml4;
   return pml4
 od"

text {* Format a VM fault message to be passed to a thread's supervisor after
it encounters a page fault. *}
fun
handle_vm_fault :: "obj_ref \<Rightarrow> vmfault_type \<Rightarrow> (unit,'z::state_ext) f_monad"
where
"handle_vm_fault thread fault_type = doE
    addr \<leftarrow> liftE $ do_machine_op getFaultAddress;
    fault \<leftarrow> liftE $ as_user thread $ getRegister ErrorRegister;
    case fault_type of
        X64DataFault \<Rightarrow> throwError $ VMFault addr [0, fault && mask 5]
      | X64InstructionFault \<Rightarrow> throwError $ VMFault addr [1, fault && mask 5]
odE"

(* FIXME x64: should be a machine interface op/imported from Haskell *)
definition
  setCurrentVSpaceRoot :: "machine_word \<Rightarrow> asid \<Rightarrow> unit machine_monad" where 
  "setCurrentVSpaceRoot pml4 asid = undefined"


text {* Switch into the address space of a given thread or the global address
space if none is correctly configured. *}
definition
  set_vm_root :: "obj_ref \<Rightarrow> (unit,'z::state_ext) s_monad" where
"set_vm_root tcb \<equiv> do
    thread_root_slot \<leftarrow> return (tcb, tcb_cnode_index 1);
    thread_root \<leftarrow> get_cap thread_root_slot;
    (case thread_root of
       ArchObjectCap (PML4Cap pml4 (Some asid)) \<Rightarrow> doE
           pml4' \<leftarrow> find_vspace_for_asid asid;
           whenE (pml4 \<noteq> pml4') $ throwError InvalidRoot;
           liftE $ do_machine_op $ setCurrentVSpaceRoot (addrFromPPtr pml4) asid
       odE
     | _ \<Rightarrow> throwError InvalidRoot) <catch>
    (\<lambda>_. do
       global_pml4 \<leftarrow> gets (x64_global_pml4 \<circ> arch_state);
       do_machine_op $ setCurrentVSpaceRoot (addrFromKPPtr global_pml4) 0
    od)
od"

definition
delete_asid_pool :: "asid \<Rightarrow> obj_ref \<Rightarrow> (unit,'z::state_ext) s_monad" where
"delete_asid_pool base ptr \<equiv> do
  assert (base && mask asid_low_bits = 0);
  asid_table \<leftarrow> gets (x64_asid_table \<circ> arch_state);
  when (asid_table (asid_high_bits_of base) = Some ptr) $ do
    asid_table' \<leftarrow> return (asid_table (asid_high_bits_of base:= None));
    modify (\<lambda>s. s \<lparr> arch_state := (arch_state s) \<lparr> x64_asid_table := asid_table' \<rparr>\<rparr>);
    tcb \<leftarrow> gets cur_thread;
    set_vm_root tcb
  od
od"

text {* When deleting a page map level 4 from an ASID pool we must deactivate
it. *}
definition
delete_asid :: "asid \<Rightarrow> obj_ref \<Rightarrow> (unit,'z::state_ext) s_monad" where
"delete_asid asid pml4 \<equiv> do
  asid_table \<leftarrow> gets (x64_asid_table \<circ> arch_state);
  do_machine_op $ hwASIDInvalidate asid;
  case asid_table (asid_high_bits_of asid) of
    None \<Rightarrow> return ()
  | Some pool_ptr \<Rightarrow>  do
     pool \<leftarrow> get_asid_pool pool_ptr;
     when (pool (ucast asid) = Some pml4) $ do
                pool' \<leftarrow> return (pool (ucast asid := None));
                set_asid_pool pool_ptr pool';
                tcb \<leftarrow> gets cur_thread;
                set_vm_root tcb
            od
    od
od"

(* FIXME x64: should be in hardware interface *)
definition
  resetCR3 :: "unit machine_monad" where
  "resetCR3 = undefined"

definition
  flush_all :: "(unit,'z::state_ext) s_monad" where
  "flush_all = do_machine_op resetCR3"

definition
  flush_pdpt :: "(unit,'z::state_ext) s_monad" where
  "flush_pdpt = flush_all"

definition
  flush_pd :: "(unit,'z::state_ext) s_monad" where
  "flush_pd = flush_all"

text {* Flush mappings associated with a page table. *}
definition
flush_table :: "obj_ref \<Rightarrow> vspace_ref \<Rightarrow> obj_ref \<Rightarrow> (unit,'z::state_ext) s_monad" where
"flush_table vspace vptr pt \<equiv> do
    assert (vptr && mask (ptTranslationBits + pageBits) = 0);
    tcb \<leftarrow> gets cur_thread;
    thread_root_slot \<leftarrow> return (tcb, tcb_cnode_index 1);
    thread_root \<leftarrow> get_cap thread_root_slot;
    case thread_root of
       ArchObjectCap (PML4Cap vspace' (Some _)) \<Rightarrow>
         when (vspace = vspace') $ do
           pt \<leftarrow> get_pt pt;
           forM_x [0 .e. (-1::9 word)] (\<lambda>index. do
             pte \<leftarrow> return $ pt index;
             case pte of
               InvalidPTE \<Rightarrow> return ()
             | _ \<Rightarrow> do_machine_op $ invalidateTLBEntry (vptr + (ucast index << pageBits))
           od)
         od
       | _ \<Rightarrow> return ()
od"


(* FIXME x64: should be in hardware interface *)
definition
  invalidatePageStructureCache :: "unit machine_monad" where
  "invalidatePageStructureCache = undefined"


text {* Unmap a Page Directory Pointer Table from a PML4. *}
definition
unmap_pdpt :: "asid \<Rightarrow> vspace_ref \<Rightarrow> obj_ref \<Rightarrow> (unit,'z::state_ext) s_monad" where
"unmap_pdpt asid vaddr pdpt \<equiv> doE
  vspace \<leftarrow> find_vspace_for_asid asid;
  pm_slot \<leftarrow> returnOk $ lookup_pml4_slot vspace vaddr;
  pml4e \<leftarrow> liftE $ get_pml4e pm_slot;
  case pml4e of
    PDPointerTablePML4E pt' _ _ \<Rightarrow> 
      if pt' = addrFromPPtr pdpt then returnOk () else throwError InvalidRoot
    | _ \<Rightarrow> throwError InvalidRoot;
  liftE $ do
    flush_pdpt;
    store_pml4e pm_slot InvalidPML4E
  od
odE <catch> (K $ return ())"

text {* Unmap a Page Directory from a Page Directory Pointer Table. *}
definition
unmap_pd :: "asid \<Rightarrow> vspace_ref \<Rightarrow> obj_ref \<Rightarrow> (unit,'z::state_ext) s_monad" where
"unmap_pd asid vaddr pd \<equiv> doE
  vspace \<leftarrow> find_vspace_for_asid asid;
  pdpt_slot \<leftarrow> lookup_pdpt_slot vspace vaddr;
  pdpte \<leftarrow> liftE $ get_pdpte pdpt_slot;
  case pdpte of
    PageDirectoryPDPTE pd' _ _ \<Rightarrow> 
      if pd' = addrFromPPtr pd then returnOk () else throwError InvalidRoot
    | _ \<Rightarrow> throwError InvalidRoot;
  liftE $ do
    store_pdpte pdpt_slot InvalidPDPTE;
    do_machine_op invalidatePageStructureCache
  od
odE <catch> (K $ return ())"

text {* Unmap a page table from its page directory. *}
definition
unmap_page_table :: "asid \<Rightarrow> vspace_ref \<Rightarrow> obj_ref \<Rightarrow> (unit,'z::state_ext) s_monad" where
"unmap_page_table asid vaddr pt \<equiv> doE
    vspace \<leftarrow> find_vspace_for_asid asid;
    pd_slot \<leftarrow> lookup_pd_slot vspace vaddr;
    pde \<leftarrow> liftE $ get_pde pd_slot;
    case pde of
      PageTablePDE addr _ _ \<Rightarrow> 
        if addrFromPPtr pt = addr then returnOk () else throwError InvalidRoot
      | _ \<Rightarrow> throwError InvalidRoot;
    liftE $ do 
      flush_table vspace vaddr pt;
      store_pde pd_slot InvalidPDE;
      do_machine_op $ invalidatePageStructureCache
    od
odE <catch> (K $ return ())"

text {* Check that a given frame is mapped by a given mapping entry. *}
definition
check_mapping_pptr :: "machine_word \<Rightarrow> vm_page_entry \<Rightarrow> bool" where
"check_mapping_pptr pptr entry \<equiv> case entry of
   VMPTE (SmallPagePTE base _ _) \<Rightarrow> base = addrFromPPtr pptr
 | VMPDE (LargePagePDE base _ _) \<Rightarrow> base = addrFromPPtr pptr
 | VMPDPTE (HugePagePDPTE base _ _) \<Rightarrow> base = addrFromPPtr pptr
 | _ \<Rightarrow> False"

(* FIXME: move to generic *)
text {* Raise an exception if a property does not hold. *}
definition
throw_on_false :: "'e \<Rightarrow> (bool,'z::state_ext) s_monad \<Rightarrow> ('e + unit,'z::state_ext) s_monad" where
"throw_on_false ex f \<equiv> doE v \<leftarrow> liftE f; unlessE v $ throwError ex odE"

text {* Unmap a mapped page if the given mapping details are still current. *}
definition
unmap_page :: "vmpage_size \<Rightarrow> asid \<Rightarrow> vspace_ref \<Rightarrow> obj_ref \<Rightarrow> (unit,'z::state_ext) s_monad" where
"unmap_page pgsz asid vptr pptr \<equiv> doE
    vspace \<leftarrow> find_vspace_for_asid asid;
    case pgsz of
          X64SmallPage \<Rightarrow> doE
            pt_slot \<leftarrow> lookup_pt_slot vspace vptr;
            pte \<leftarrow> liftE $ get_pte pt_slot;
            unlessE (check_mapping_pptr pptr (VMPTE pte)) $ throwError InvalidRoot;
            liftE $ store_pte pt_slot InvalidPTE
          odE
        | X64LargePage \<Rightarrow> doE
            pd_slot \<leftarrow> lookup_pd_slot vspace vptr;
            pde \<leftarrow> liftE $ get_pde pd_slot;
            unlessE (check_mapping_pptr pptr (VMPDE pde)) $ throwError InvalidRoot;
            liftE $ store_pde pd_slot InvalidPDE
          odE
        | X64HugePage \<Rightarrow> doE
            pdpt_slot \<leftarrow> lookup_pdpt_slot vspace vptr;
            pdpte \<leftarrow> liftE $ get_pdpte pdpt_slot;
            unlessE (check_mapping_pptr pptr (VMPDPTE pdpte)) $ throwError InvalidRoot;
            liftE $ store_pdpte pdpt_slot InvalidPDPTE
          odE;
    liftE $ do
      tcb \<leftarrow> gets cur_thread;
      (* FIXME: duplication, pull this pattern out into a function; also in Haskell/C *) 
      thread_root_slot \<leftarrow> return (tcb, tcb_cnode_index 1);
      thread_root \<leftarrow> get_cap thread_root_slot;
      case thread_root of
        ArchObjectCap (PML4Cap vspace' (Some _ )) \<Rightarrow> 
          when (vspace' = vspace) $ do_machine_op $ invalidateTLBEntry vptr
        | _ \<Rightarrow> return ()
    od
odE <catch> (K $ return ())"


text {* Page table structure capabilities cannot be copied until they
have a virtual ASID and location assigned. This is because they
cannot have multiple current virtual ASIDs and cannot be shared
between address spaces or virtual locations. *}
definition
  arch_derive_cap :: "arch_cap \<Rightarrow> (arch_cap,'z::state_ext) se_monad"
where
  "arch_derive_cap c \<equiv> case c of
     PageTableCap _ (Some x) \<Rightarrow> returnOk c
   | PageTableCap _ None \<Rightarrow> throwError IllegalOperation
   | PageDirectoryCap _ (Some x) \<Rightarrow> returnOk c
   | PageDirectoryCap _ None \<Rightarrow> throwError IllegalOperation
   | PDPointerTableCap _ (Some x) \<Rightarrow> returnOk c
   | PDPointerTableCap _ None \<Rightarrow> throwError IllegalOperation
   | PML4Cap _ (Some x) \<Rightarrow> returnOk c
   | PML4Cap _ None \<Rightarrow> throwError IllegalOperation
   | PageCap r R mt pgs x \<Rightarrow> returnOk (PageCap r R mt pgs None)
   | ASIDControlCap \<Rightarrow> returnOk c
   | ASIDPoolCap _ _ \<Rightarrow> returnOk c
(* FIXME x64-vtd: *)
(*
   | IOSpaceCap _ _ \<Rightarrow> returnOk c
   | IOPageTableCap _ _ _ \<Rightarrow> returnOk c
*)
   | IOPortCap _ _ \<Rightarrow> returnOk c"

(* FIXME: update when IOSpace comes through *)
text {* No user-modifiable data is stored in x64-specific capabilities. *}
definition
  arch_update_cap_data :: "data \<Rightarrow> arch_cap \<Rightarrow> cap"
where
  "arch_update_cap_data data c \<equiv> case c of
    IOPortCap first_port_old last_port_old \<Rightarrow>
      let first_port = undefined data; (* ioPortGetFirstPort *)
          last_port = undefined data (* ioPortGetLastPort *) in
        if (first_port_old \<le> last_port_old)
        then
          if (first_port \<le> last_port \<and> first_port \<ge> first_port_old \<and> last_port \<le> last_port_old)
          then ArchObjectCap $ IOPortCap first_port last_port
          else NullCap
        else undefined
  | _ \<Rightarrow> ArchObjectCap c"


text {* Actions that must be taken on finalisation of x64-specific
capabilities. *}
definition
  arch_finalise_cap :: "arch_cap \<Rightarrow> bool \<Rightarrow> (cap,'z::state_ext) s_monad"
where
  "arch_finalise_cap c x \<equiv> case (c, x) of
    (ASIDPoolCap ptr b, True) \<Rightarrow>  do
    delete_asid_pool b ptr;
    return NullCap
    od
  | (PML4Cap ptr (Some a), True) \<Rightarrow> do
    delete_asid a ptr;
    return NullCap
  od
  | (PDPointerTableCap ptr (Some (a,v)), True) \<Rightarrow> do
    unmap_pdpt a v ptr;
    return NullCap
  od
  | (PageDirectoryCap ptr (Some (a,v)), True) \<Rightarrow> do
    unmap_pd a v ptr;
    return NullCap
  od
  | (PageTableCap ptr (Some (a, v)), True) \<Rightarrow> do
    unmap_page_table a v ptr;
    return NullCap
  od
  | (PageCap ptr _ _ s (Some (a, v)), _) \<Rightarrow> do
     unmap_page s a v ptr;
     return NullCap
  od
  (* FIXME: IOSpaceCap and IOPageTableCap *)
  | _ \<Rightarrow> return NullCap"


text {* Remove record of mappings to a page cap, page table cap or page directory cap *}

fun
  arch_reset_mem_mapping :: "arch_cap \<Rightarrow> arch_cap"
where
  "arch_reset_mem_mapping (PageCap p rts mt sz mp) = PageCap p rts mt sz None"
| "arch_reset_mem_mapping (PageTableCap ptr mp) = PageTableCap ptr None"
| "arch_reset_mem_mapping (PageDirectoryCap ptr ma) = PageDirectoryCap ptr None"
| "arch_reset_mem_mapping (PDPointerTableCap ptr ma) = PDPointerTableCap ptr None"
| "arch_reset_mem_mapping (PML4Cap ptr ma) = PML4Cap ptr None"
(* FIXME x64-vtd: *)
(*
| "arch_reset_mem_mapping (IOPageTableCap ptr lvl ma) = IOPageTableCap ptr lvl None"
*)
| "arch_reset_mem_mapping cap = cap"

text {* Actions that must be taken to recycle x64-specific capabilities. *}
definition
  arch_recycle_cap :: "bool \<Rightarrow> arch_cap \<Rightarrow> (arch_cap,'z::state_ext) s_monad"
where
  "arch_recycle_cap is_final cap \<equiv> case cap of
    PageCap p _ _ sz _ \<Rightarrow> do
      do_machine_op $ clearMemory p (2 ^ pageBitsForSize sz);
      arch_finalise_cap cap is_final;
      return $ arch_reset_mem_mapping cap
    od
  | PageTableCap ptr mp \<Rightarrow> do
      pte_bits \<leftarrow> return 3;
      slots \<leftarrow> return [ptr, ptr + (1 << pte_bits) .e. ptr + (1 << ptTranslationBits) - 1];
      mapM_x (swp store_pte InvalidPTE) slots;
      case mp of 
         None \<Rightarrow> return ()
       | Some (a, v) \<Rightarrow> unmap_page_table a v ptr;
      arch_finalise_cap cap is_final;
      return (if is_final then arch_reset_mem_mapping cap else cap)
    od
  | PageDirectoryCap ptr ma \<Rightarrow> do
      pde_bits \<leftarrow> return 3;
      slots \<leftarrow> return [ptr, ptr + (1 << pde_bits) .e. ptr + (1 << ptTranslationBits) - 1];
      mapM_x (swp store_pde InvalidPDE) slots;
      case ma of
        None \<Rightarrow> return ()
      | Some (a,v) \<Rightarrow> unmap_pd a v ptr;
      arch_finalise_cap cap is_final;
      return (if is_final then arch_reset_mem_mapping cap else cap)
    od
  | PDPointerTableCap ptr ma \<Rightarrow> do
      pdpte_bits \<leftarrow> return 3;
      slots \<leftarrow> return [ptr, ptr + (1 << pdpte_bits) .e. ptr + (1 << ptTranslationBits) - 1];
      mapM_x (swp store_pdpte InvalidPDPTE) slots;
      case ma of
        None \<Rightarrow> return ()
      | Some (a,v) \<Rightarrow> unmap_pdpt a v ptr;
      arch_finalise_cap cap is_final;
      return (if is_final then arch_reset_mem_mapping cap else cap)
    od
  | PML4Cap ptr ma \<Rightarrow> do
      pml4e_bits \<leftarrow> return 3;
      slots \<leftarrow> return [ptr, ptr + (1 << pml4e_bits) .e. ptr + (1 << ptTranslationBits) - 1];
      mapM_x (swp store_pml4e InvalidPML4E) slots;
      arch_finalise_cap cap is_final;
      return (if is_final then arch_reset_mem_mapping cap else cap)
    od
  | ASIDControlCap \<Rightarrow> return ASIDControlCap
  | ASIDPoolCap ptr base \<Rightarrow> do
      asid_table \<leftarrow> gets (x64_asid_table \<circ> arch_state);
      when (asid_table (asid_high_bits_of base) = Some ptr) $ do
          delete_asid_pool base ptr;
          set_asid_pool ptr empty;
          asid_table \<leftarrow> gets (x64_asid_table \<circ> arch_state);
          asid_table' \<leftarrow> return (asid_table (asid_high_bits_of base \<mapsto> ptr));
          modify (\<lambda>s. s \<lparr> arch_state := (arch_state s) \<lparr> x64_asid_table := asid_table' \<rparr>\<rparr>)
      od;
      return cap
    od
  | IOPortCap _ _ \<Rightarrow> return cap"
(* FIXME x64-vtd: *)
(*
  | IOSpaceCap _ _  \<Rightarrow> do
     arch_finalise_cap cap is_final;
     return cap
    od
  | IOPageTableCap ptr _ mp \<Rightarrow> undefined (* FIXME: TODO *)"
*)


text {* A thread's virtual address space capability must be to a mapped PML4 (page map level 4)
to be valid on the x64 architecture. *}
definition
  is_valid_vtable_root :: "cap \<Rightarrow> bool" where
  "is_valid_vtable_root c \<equiv> \<exists>r a. c = ArchObjectCap (PML4Cap r (Some a))"

text {* A thread's IPC buffer capability must be to a page that is capable of
containing the IPC buffer without the end of the buffer spilling into another
page. *}
definition
  cap_transfer_data_size :: nat where
  "cap_transfer_data_size \<equiv> 3"

definition
  msg_max_length :: nat where
 "msg_max_length \<equiv> 120"

definition
  msg_max_extra_caps :: nat where
 "msg_max_extra_caps \<equiv> 3"

definition
  msg_align_bits :: nat
  where
  "msg_align_bits \<equiv> 2 + (LEAST n. (cap_transfer_data_size + msg_max_length + msg_max_extra_caps + 2) \<le> 2 ^ n)"

lemma msg_align_bits:
  "msg_align_bits = 9"
proof -
  have "(LEAST n. (cap_transfer_data_size + msg_max_length + msg_max_extra_caps + 2) \<le> 2 ^ n) = 7"
  proof (rule Least_equality)
    show "(cap_transfer_data_size + msg_max_length + msg_max_extra_caps + 2)  \<le> 2 ^ 7"
      by (simp add: cap_transfer_data_size_def msg_max_length_def msg_max_extra_caps_def)
  next
    fix y
    assume "(cap_transfer_data_size + msg_max_length + msg_max_extra_caps + 2) \<le> 2 ^ y"
    hence "(2 :: nat) ^ 7 \<le> 2 ^ y"
      by (simp add: cap_transfer_data_size_def msg_max_length_def msg_max_extra_caps_def)
    thus "7 \<le> y"
      by (rule power_le_imp_le_exp [rotated], simp)
  qed
  thus ?thesis unfolding msg_align_bits_def by simp
qed

definition
check_valid_ipc_buffer :: "vspace_ref \<Rightarrow> cap \<Rightarrow> (unit,'z::state_ext) se_monad" where
"check_valid_ipc_buffer vptr c \<equiv> case c of
  (ArchObjectCap (PageCap _ _ _ _ _)) \<Rightarrow> doE
    whenE (\<not> is_aligned vptr msg_align_bits) $ throwError AlignmentError;
    returnOk ()
  odE
| _ \<Rightarrow> throwError IllegalOperation"

(* FIXME: move vm_rights to generic *)
text {* On the abstract level, capability and VM rights share the same type.
  Nevertheless, a simple set intersection might lead to an invalid value like
  @{term "{AllowWrite}"}.  Hence, @{const validate_vm_rights}. *}
definition
  mask_vm_rights :: "vm_rights \<Rightarrow> cap_rights \<Rightarrow> vm_rights" where
  "mask_vm_rights V R \<equiv> validate_vm_rights (V \<inter> R)"

text {* Decode a user argument word describing the kind of VM attributes a
mapping is to have. *}
definition
attribs_from_word :: "machine_word \<Rightarrow> frame_attrs" where
"attribs_from_word w \<equiv>
  let V = (if w !!0 then {PTAttr WriteThrough} else {});
      V' = (if w!!1 then insert PAT V else V)
  in if w!!2 then insert (PTAttr CacheDisabled) V' else V'"


text {* Update the mapping data saved in a page or page table capability. *}
definition
  update_map_data :: "arch_cap \<Rightarrow> (asid \<times> vspace_ref) option \<Rightarrow> arch_cap" where
  "update_map_data cap m \<equiv> case cap of 
     PageCap p R mt sz _ \<Rightarrow> PageCap p R mt sz m
   | PageTableCap p _ \<Rightarrow> PageTableCap p m
   | PageDirectoryCap p _ \<Rightarrow> PageDirectoryCap p m
   | PDPointerTableCap p _ \<Rightarrow> PDPointerTableCap p m"

text {*
  A pointer is inside a user frame if its top bits point to a @{text DataPage}.
*}
definition
  in_user_frame :: "obj_ref \<Rightarrow> 'z::state_ext state \<Rightarrow> bool" where
  "in_user_frame p s \<equiv>
   \<exists>sz. kheap s (p && ~~ mask (pageBitsForSize sz)) =
        Some (ArchObj (DataPage sz))"

end
end