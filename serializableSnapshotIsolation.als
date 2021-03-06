/*
   An Alloy model of Cahill's algorithm for serializable snapshot isolation

     Paper: 		http://cahill.net.au/wp-content/uploads/2009/01/real-serializable.pdf
     PhD thesis:	http://cahill.net.au/wp-content/uploads/2010/02/cahill-thesis.pdf

   This is a modification of textbookSnapshotIsolation.als
   Alloy would allow the common parts to be factored into a shared module, 
   but I've chosen to keep them as single stand-alone files for now, 
   to make them easier to read and experiment with. 
   
   This specification includes various correctness properties, including 
   serializability, which can be checked by the Alloy Analyzer for 
   all possible sequences of operations by a small number of transactions (e.g. 3 or 4)
   over a small number of keys (e.g. 2 or 3)
   
   Instructions: 

	1. Download Alloy Analyzer v4 from http://alloy.mit.edu/alloy4/
		I tested with v4.1.10

	2. Click 'Open' and load this model (text file).  

	3. Click (menu) Options...SAT Solver...MiniSat

	4. Click 'Execute'.   
		It is currently set up to find an instance in which a transaction is aborted 
		by Cahill's algorithm, to ensure serializability.
		This analysis takes about 15 seconds.  Other checks might take hours or days.

	5. Click 'Show'.    Don't worry about the complex graph that appears.  

	6. Click the "Magic Layout" button and "Yes, clear the current settings"
		The display will now represent a single state of the system, 
		with keys and transactions as nodes, 
		and relationships as labelled. arcs 

	7. Use the "<<" and ">>" arrow buttons at the bottom of the screen to move forwards 
        and backwards through logical time steps.  
        Be sure to always start at Time$0 -- sometimes the tool shows a different time first.

	8. Click "Next" in the toolbar to look at the next counter-example, if there is one.  
		'Next' doesn't reset the time, so use << to start at Time$0.

	9. Try examining different interesting conditions, or verifying some properties.   
		You'll need to edit this file, in the section marked "Analysis"
        E.g. The file is currently set to execute the following command,
		which finds an instance (example) which satisfies both of the listed conditions:

			run {
					at_least_n_txn_abort_to_preserve_serializability[1]
			} for 2 but 12 Time, 3 TxnId, 3 Key

		You might change it to this, to verify serializability:

			check { cahill_serializable } for 2 but 15 Time, 4 TxnId, 3 Key

	8. Learn the Alloy language & tool via the tutorials listed at http://alloy.mit.edu/alloy4/
		The best place to start is probably this one:  http://alloy.mit.edu/alloy4/tutorial4/ 

	9. For more depth, read Jackson's book: 
		http://www.amazon.com/Software-Abstractions-Logic-Language-Analysis/dp/0262101149
*/

open util/ordering [Time] as TimeOrder

// This algorithm for snapshot isolation is not based on timestamp ordering 
// (of start times of transactions), so we don't need TxnIds to be ordered for that reason.
// However, we do use TxnIds as "version ids" for keys, so we need TxnId to be ordered 
// for that reason.
//
// When using TxnIds as version ids, we must constrain the begin() action to only 
// start transactions in increasing order of TxnId (rather than in arbitrary order).
// This is necessary in order to ensure that the temporal ordering of (committed) matches
// the order of their version ids (writer TxnIds).
// That doesn't lose generality (transactions can still read, write, commit or abort 
// in any order).  The symmetry reduction also makes visualization slightly easier 
// and might reduce the cpu-time to check the model.

open util/ordering [TxnId] as TxnIdOrder

sig Time {}		
sig Key {}
sig TxnId {		
	// Sets of transactions that are now or have previously been in this state
	// (i.e. these sets monotonically grow over time)
    //
    // note; We explicitly record 'begin' steps (in 'started'), so that we know the 
    // precise lifetime of a transaction; the algorithms for snapshot isolation 
    // depend on whether transaction lifetimes overlap, i.e. whether they are concurrent.
    // If we simply infered the 'start' time as the time of the first read or write or 
    // waiting-for-lock etc. then we would fail to modle transactions that begin and 
    // then do nothing for a while.  It's not obvious that it is safe to ignore that 
    // set of executions.
    started:			set Time,
    committed:		set Time,
    aborted:			set Time,

	// These relations grow monotonically over time because they act as 'history 
	// variables', recording the sequence of transaction operations. 
	// Part of this history (for active concurrent transactions, plus the most recent 
	// commit to each key before the oldest active transaction) is required by
	// the algorithm that implements Snapshot Isolation.
	// The full history is required to test the correctness conditions (e.g. serializability).
	//
	read:				Key -> TxnId -> Time,	// ReaderTxnId -> Key -> VersionIdThatWasRead -> Time
	written:			Key -> Time,					// WriterTxnId -> Key -> Time

	// These relations model the lock manager, used by the implementation of snapshot isolation.
	// These do NOT grow monotonically over time, as locks can be both acquired and released.
	// (It is much easier to model 

	waitingForXLock: 	Key -> Time,
	holdingXLock: 		Key -> Time,

	// Extra state required for the SERIALIZABLE algorithm

	// 'txn in inConflict.t' means there is a rw-conflict from some other concurrent 
    // transaction to txn.  
    // By the definition of rw-conflict this means that 
    // txn has written a version of a key that is later than the version read by some 
    // other concurrent transaction.
    //
	// a rw dependency is;
	// - T1 reads a version of x, and T2 produces a later version of x (this is a rw-dependency, also
	//        known as an anti-dependency, and is the only case where T1 and T2 can run concurrently).
	//
	inConflict:				set Time,

	// 'txn in outConflict.t' means there is a rw-conflict from txn to some other 
    // concurrent transaction
    // By the definition of rw-conflict this means that 
    // txn has read a version of a key that is earlier than the version written by some 
    // other concurrent transaction.
    //
	outConflict:			set Time,

    // Lifetime of inConflict and outConflict;
    // If a txn aborts, we do remove it from inConflict, outConflict.
    // But if a txn commits, we *don't* remove a txn from those fields.  
    // That's how we model the part of the algorithm that requires bookeeping to 
    // be maintained for committed transactions at least until all transactions concurrent
    // with the committed transaction has aborted.   (With the current model we don't 
    // bother to do that cleanup as it is purely an optimization and does not affect 
    // semantics.)

    // txn in holdingSiREADlock.t[k] means that txn has read k. 
    // SiREAD locks don't block readers or writers.
    // Unlike normal locks, SiREAD locks continue to be held AFTER txn commits.   
    // They can be released for a particular txn when all transactions concurrent with 
    // that txn have finalized.  For this model we don't bother to do that, as it is purely 
    // an optimization, and does not affect semantics.
    // If a txn aborts then SiREAD locks are released immediately for that txn.
    //
	holdingSIREADlock: Key -> Time,

	// This field is only present to help find interesting instances to visualize.
	// It is not required by the algorithm.
	// It does grow monotonically with time.  
	// If txn is in abortedToPreserveSerializability.t then it is also in aborted.t.
	
	abortedToPreserveSerializability: set Time
}

// Helper for enabling conditions of public operations
pred txn_started_and_can_do_public_operations[t: Time, txn: TxnId] {

	let time_up_to_and_including_t = (TimeOrder/prevs[t] + t) {

	    // Must have been started at or before time t 
		txn in started.time_up_to_and_including_t

		// ... and not committed or aborted before time t
		txn not in (committed + aborted).time_up_to_and_including_t
	}

	// And not currently blocked waiting for a lock.  
	// (If a transaction is blocked waiting for a lock then an *internal* operation 
	// can become enabled that will allow the transaction to make progress -- 
	// e.g. the lock might become free and the transaction might be the one that 
	// acquires the lock.  But that operation is not a 'public' operation.)

	no txn.waitingForXLock.t
}

// Public operations (actions)

pred begin[t, t': Time, txn: TxnId] {
	/* http://cahill.net.au/wp-content/uploads/2009/01/real-serializable.pdf

		existing SI code for begin(T)
		set T.inConflict = T.outConflict = false
	*/

	si_begin[t, t', txn]

	// By definition txn cannot be in inConflict, outConflict, holdingSiREADlock etc.
	// (We have asserts that very that property of basic model correctness.)
	// So we just have a frame condition for that state:
	inConflict.t'					= inConflict.t
	outConflict.t'					= outConflict.t
	holdingSIREADlock.t'	= holdingSIREADlock.t
	abortedToPreserveSerializability.t' = abortedToPreserveSerializability.t
}

pred si_begin[t, t': Time, txn: TxnId] {

	// Enabling condition
	// Purely for the purposes of the model, we artificially constrain 
	// transactions to start in order of increasing TxnId, with this:
	//
	//		started.t = TxnIdOrder/prevs[txn]	
	//
	// This allows us to use TxnId as VersionIds for keys.
	//
	// The goal of using TxnIds for VersionIds is:
	//		- make visualization simpler (so the user can anticipate which transaction will start next)
	// 		- reduce model-checking time by avoiding the symmetry of permuted TxnIds.
	//		- avoid the need for a sig of explicit VersionIds (reduce model complexity and model checking time)
	//		- avoid the obvious use of Time atoms as version ids, because we want to 'project' the visualization on Time, and that would hide any use of Time atoms as version-ids etc..
	//
	// This optimization does not affect the thoroughness of model-checking,
	// (i.e. does not lose generality), because nothing else depends on any ordering 
	// of TxnId.
	//
	// Correctness argument:
	//
	//	The property we need is that,
	//		for each key, *committed* version ids are monotonically increasing with time.
	//
	// When using TxnIds as VersionIds, this becomes:
	//		for each key, the TxnIds of *committed* writers to that key 
	//		are monotonically increasing with time.
	//
	// The checks for basic_model_correctness verify that is true for 
	// all executions; see safe_to_use_txnids_as_key_versionids.
	//
	// We implement this temporal constraint by these rules:
	//		a. Constraining transactions to start in increasing order of TxnId
	//		b. The standard SI FirstCommitterWins rule ensures that if any set of concurrent 
	//		   transactions write to the same key, at most one of them can commit.
	//
	// As SI *never* does uncommitted reads, the above 2 properties imply that for 
	// all *committed* writes to a given key, the TxnId of the writer is monotonically 
	// increasing with time.  
	//
	// Proof; We assume the contrary (that for some key k, the TxnIds of *committed*
	// writes to that key are not monotonically increasing in time), and show a 
	// contradiction.  Non-monotonic ordering means that there exist distinct 
	// transactions Ti and Tj, with Ti < Tj, that both write to the same key and then 
	// Tj commits before Ti.  Rule (a) implies that Tj started after Ti, and by definition 
	// Tj commits before Ti; therefore Ti and Tj are concurrent transactions that both 
	// modify the same key, and both commit.  But rule (b) says that at most one of 
	// Ti and Tj can commit; a contradiction.
	//
	started.t = TxnIdOrder/prevs[txn]	

	// Postcondition
    started.t' 					= started.t + txn

	// Frame condition
    read.t'						= read.t
    written.t'					= written.t
    committed.t'				= committed.t
    aborted.t'					= aborted.t
	waitingForXLock.t' 	= waitingForXLock.t
	holdingXLock.t' 		= holdingXLock.t
}


pred read[t, t': Time, txn: TxnId, k: Key] {
	/* http://cahill.net.au/wp-content/uploads/2009/01/real-serializable.pdf

	get lock(key=x, owner=T, mode=SIREAD)
	if there is a WRITE lock(wl) on x {
		set wl.owner.inConflict = true
		set T.outConflict = true
	}

	// existing SI code for read(T, x)

	for each version (xNew) of x that is newer than what T read:
		if xNew.creator is committed and xNew.creator.outConflict: {
			abort(T)
		}
		else {
			set xNew.creator.inConflict = true
			set T.outConflict = true
		}
	*/
	// The structure of the above algorithm completely relies on mutability of fields 
	// and early returns.
	// We have to almost completely re-order the algorithm, to state it as a 
	// functional constraint on execution traces.


	// We have to state the enabling conditions here, because
	// one path through this does abort[t,t',txn] instead of si_read[t,t',txn,k]
	// and we want the same enabling conditions (plus those below) for the abort.
	si_read_enabling_conditions[t, t', txn, k]


	let versionid_of_k_read_by_txn 
			= versionid_of_k_that_would_be_read_by_txn[t, txn, k],

		// ... this might contain *uncommitted* versions (that's really the point)	
		versionids_of_k_newer_than_read_by_txn
			= (written.t).k - (versionid_of_k_read_by_txn 
										+ TxnIdOrder/prevs[versionid_of_k_read_by_txn]) {

		// for each version (xNew) of x that is newer than what T read:
		// 	if xNew.creator is committed and xNew.creator.outConflict: {
		//		abort(T)
		// 	}
		// 	else {
		//		set xNew.creator.inConflict = true
		//		set T.outConflict = true
		// 	}

		(some xNew: versionids_of_k_newer_than_read_by_txn |
				xNew in committed.t  and  xNew in outConflict.t) 
			=> {
					// This read might not be serializable; we must abort.
					// Specifically, this read by txn will set up a rw-conflict from txn to xnew.
					// And xnew already has a rw-conflict from xnew to some transaction Tout.
					// (note; Tout may or may not be txn).
					// Therefore this read could cause a 'dangerous structure' in the 
					// conflict graph (two consecutive rw-conflict edges that might be 
					// part of a cycle), with xnew as the 'pivot transaction'.
					// We would prefer to abort the pivot, but it has already committed.
					// So to (conservatively) ensure safety, we must abort.
					abort_to_preserve_serializability[t, t', txn]
				}
				else {
					// The read is safe.  But it might still build towards a 'dangerous structure' 
					// in the conflict graph, so we have to do the necessary book-keeping 
					// to track that, as well as doing the read.

					// (note; unlike the statement of the algorithm in the paper, we only 
					// in this model we only acquire the SIREAD lock if the read is allowed 
					// -- i.e. if txn does not abort because of the read.  Otherwise 
					// acquring the SiREAD lock line would conflict with the 
					// dropping of the same lock in abort[], and the model would be 
					// over-constrained -- the abort could never occur, and so would implicitly 
					// become part of the enabling condition.  i.e. The model checker would 
					// never consider read attempts that might violate serializability, so the 
					// entire point of the model would be wasted.)
 
					holdingSIREADlock.t' = holdingSIREADlock.t + txn->k

					// do the normal snapshot isolation read
					si_do_read[t, t', txn, k]

					// The form of the algorithm in the paper treats inConflict and outConflict
					// as mutable flags local to each transaction.  Purely due to the natural 
					// modelling idiom in Alloy, in our model inConflict and outConflict are 
					// single global relations.  So we have to compute the full final constraint 
					// on the next state of each of those relations in one go.  This means changing 
					// the form of the algorithm, although we want the same semantics.
					// Those semantics are;
					//
					// 	if there is a WRITE lock(wl) on x {
					// 		set wl.owner.inConflict = true
					// 		set T.outConflict = true
					// 	}
					// 	for each version (xNew) of x that is newer than what T read:
					// 		if xNew.creator is committed and xNew.creator.outConflict: {
					// 			// abort(T) --- handled earlier
					// 		}
					// 		else {
					// 			set xNew.creator.inConflict = true
					// 			set T.outConflict = true
					// 		}

					// ToDo; when considering whether there is a WRITE lock on x, 
					// should we include or ignore write-locks held by txn itself?
					// Michael's paper does not mention doing that, so currently 
					// we DON'T include write locks held by txn itself.

					inConflict.t' = inConflict.t 
							+ versionids_of_k_newer_than_read_by_txn
							+ ((holdingXLock.t).k - txn)		// xlock_owner, if there is one 

					(	some versionids_of_k_newer_than_read_by_txn 
					or	( some xlock_owner: TxnId - txn |
								k in xlock_owner.holdingXLock.t  // 'there is a WRiTE lock on x' 
						)
					)
						=> {
							outConflict.t' = outConflict.t + txn				
						}
						else {
							// frame condition
							outConflict.t' = outConflict.t
						}		

					// Frame condition
					abortedToPreserveSerializability.t' = abortedToPreserveSerializability.t
				}
		}
}

pred si_read_enabling_conditions[t, t': Time, txn: TxnId, k: Key] {
	
	txn_started_and_can_do_public_operations[t, txn]

	// Bernstein's standard simplification to the model: 
	// no txn reads the same key more than once.
	no txn.read.t[k]	

	// We don't model 'missing' keys, so there must already be a version of k 
	// that it is legal for us to read
	some versionid_of_k_that_would_be_read_by_txn[t, txn, k]
}

pred si_do_read[t, t': Time, txn: TxnId, k: Key] {

	si_read_enabling_conditions[t, t', txn, k]

	let versionid_to_read = versionid_of_k_that_would_be_read_by_txn[t, txn, k] {

		read.t' = read.t + txn->k->versionid_to_read

	    started.t'					= started.t
	    written.t'					= written.t
	    committed.t'				= committed.t
	    aborted.t'					= aborted.t
		waitingForXLock.t' 	= waitingForXLock.t
		holdingXLock.t' 		= holdingXLock.t
	}
}

// Helper.  Assumes "one time_of_start(txn)"
fun versionid_of_k_that_would_be_read_by_txn[t: Time, txn: TxnId, k: Key] 
	: lone TxnId
{
	txn in (written.t).k
		=> 
			// txn reads the (uncommitted) version that it wrote itself before t
			txn			
		else 
			// txn reads the latest version that was committed before txn began
			TxnIdOrder/max
				[	all_versionids_of_k_created_before_t_by_txns_committed_before_t
							[time_of_start[txn], k] 
					&	TxnIdOrder/prevs[txn]
				]
}

fun all_versionids_of_k_created_before_t_by_txns_committed_before_t[t: Time, k: Key] 
	: set TxnId 
{
	let all_versionids_of_k_created_before_t = (written.t).k,	// set of writer TxnId at t
		 all_txnids_committed_before_t = committed.t | 			// set of committed TxnId at t

			all_versionids_of_k_created_before_t & all_txnids_committed_before_t
}


/* Modified write algorithm, from http://cahill.net.au/wp-content/uploads/2009/01/real-serializable.pdf

	get lock(key=x, locker=T, mode=WRITE)

	if there is a SIREAD lock(rl) on x with rl.owner is running or commit(rl.owner) > begin(T): {
		if rl.owner is committed and rl.owner.inConflict: {
			abort(T)
		}
		else {
			set rl.owner.outConflict = true
			set T.inConflict = true
		}
	}

	existing SI code for write(T, x, xNew)
	# do not get WRITE lock again
	*/

// Note we put most of the above logic into write_can_acquire_xlock[]
// as that is the predicate that always handles the write once we know for sure that 
// this transaction can acquire the write lock. 

pred start_write_may_block[t, t': Time, txn: TxnId, k: Key] {
	txn_started_and_can_do_public_operations[t, txn]

	// Berstein's standard simplification to the model: 
	// no txn writes to the same key more than once.
	k not in txn.written.t	

	// Part of First Commiter Wins rule: if txn attempts to write to a key that has 
	// been modified and committed since txn began, then txn cannot possibly 
	// commit, so we might as well abort txn now.
	//
	// Alternative: we could just fail the individual write, and allow the transaction
	// to proceed.  (We could model that by including the above FCW check in the 
	// enabling-condition, so that Alloy doesn't even attempt to generate behaviors 
	// that attempt to violate the FCW rule in that way.)   
	// I choose to not do that, as in the vast majority of cases the transaction 
	// won't have any realistic alternative than abort, so we simply model the abort.

	some versions_of_k_committed_since_txn_began_and_before_t[t, txn, k]  => {

		// This write would be pointless, due to the FCW rule (see above).
		abort[t, t', txn]
	}
	else {
		// This write is not forbidden by the FCW rule.

		// Do we need to wait for this key's xlock before we can write?
		//
		// (Note that we know that txn itself cannot already be holding the xlock, 
		// as our enabling-conditions prevent a transaction from writing 
		// to a key more than once.  But we do the correct test anyway (i.e. don't 
		// wait for a lock if txn already holds it), incase we ever do choose to model 
		// transactions that can write to the same key more than once

		some (holdingXLock.t).k - txn => {

			// The key is locked by some other transaction.
			// We will need to block to acquire the xlock before we can do the write.
			// But blocking on xlocks could cause deadlock, so the following predicate detects 
			// and prevents that.  The following predicate may abort txn or any other transaction
			// that would be involved in a potential cycle in the waiting-for-locks graph.
			// If this predicate does not abort txn, then when it returns, 
			// txn will be blocked on the xlock (txn->k will be in waitingForXLock.t'),
			// and an internal action, finish_blocked_write[], will later become enabled if the 
			// lock becomes free.  (Note that any number of txns might be waiting for 
			// the same xlock.  The order of acquisition is intentionall non-deterministic, 
			// to force Alloy to check all possibilities.)

			write_conflicts_with_xlock[t, t', txn, k]
		}
		else	{
			// Key is not locked -- so we can immediately acquire the xlock.
			// and attempt to do the write.  
			// (In textbook snapshot isolation we could unconditionally do the write 
			// after acquiring the lock.  But in serializable snapshot isolation we might 
			// need to aort txn to avoid violating serializability.)

			write_can_acquire_xlock[	t, t', txn, k]
		}
	}
}

// Helper for start_write_may_block
fun versions_of_k_committed_since_txn_began_and_before_t[t: Time, txn: TxnId, k: Key] 
	: set TxnId {

	// written is: WriterTxnId -> Key -> Time
	(written.(TimeOrder/prevs[t] - TimeOrder/prevs[time_of_start[txn]])).k 
			& committed.t
}

// Helper for start_write_may_block
pred write_conflicts_with_xlock[t, t' : Time, txn: TxnId, k: Key] {

	// Some other transaction is holding the xlock on this key
	// (In the current model txn itself cannot be holding the xlock 
	// as the current model doesn't allow a transaction to write to the 
	// same key twice.)
	// To write to this key, we must acquire the xlock.
	// But if waiting for the xlock would cause a deadlock
	// then we must instead abort one of the transactions 
	// involved in the cycle.

	// Standard definition of a deadlock is a cycle in the 'waiting-for-locks' graph.
	// The waiting-for-locks graph has nodes that are transactions and 
	// an edge from T1 to T2 if T2 is currently holding a lock that T1 is waiting for.
	//
	// Remember:
	// 		waitingForXLock: 	Txn->Key->Time
	// 		holdingXLock: 		Txn->Key->Time
	//
	// The current waiting-for-locks graph is therefore waitingForXLock.t 
	// dot-joined with the *transpose* of holdingXLock.t.
	// i.e.:
	//		(TxnThatIsWaitingForXLock -> KeyBeingWaitedFor)
	//	 . 	(KeyWhoseXLockIsHeld -> TxnThatIsHoldingKeysXlock)
	//
	// We want to know if a cycle would be caused in the waiting for locks graph 
	// if txn begin wait for k's xlock.  So we add txn->k to waitingForXLock.t 
	// before we do the dot join.

	let new_waiting_for_held_by = (waitingForXLock.t + txn->k).~(holdingXLock.t) {

		// If txn starting to wait on an xlock would cause a cycle, then
		// txn must be involved in that cycle, so we can check by seing 
		// if txn can reach itself.

		txn in txn.^new_waiting_for_held_by => {

			// If txn starts waiting for xlock for k, then it will cause a deadlock.

			// Pick a single transaction to abort, 
			// that would break the potential cycle in the graph.  
			// We make this a non-deterministic choice from all transactions involved in the 
			// potential cycle, to ensure that we model-check all possible choices of victim.
			// i.e. We don't enshrine a particular policy -- e.g. min write locks.

			some to_abort: txns_involved_in_cycle[new_waiting_for_held_by] {
						
				txn in to_abort => {
					// We've selected txn itself as the victim to avoid deadlock.
					abort[t, t', txn]
				}
				else {
					// We've selected some transaction other than txn as the victim to avoid deadlock.

					// Do the abort, and set txn to be waiting for the xlock.
					//
					// Note: the abort is not guaranteed to release the xlock 
					// that txn wants.  (The abort just guarantees that when txn 
					// starts waiting for the xlock, that action won't create a cycle in the 
					// waiting-for-locks graph.)
					// And we *don't* check to see if the abort has released the 
					// xlock that txn wants (to grant the xlock immediately to txn).
					// There might be other transactions waiting for the xlock
					// and we don't want to starve them.  We want to model-check 
					// all possible combinations of acquisition.

				    aborted.t' = aborted.t + to_abort
					holdingXLock.t' 	= holdingXLock.t - (to_abort <: holdingXLock.t) // drop all of to_abort's xlocks

					// txn starts waiting for the lock, 
					// and to_abort is nolonger waiting for any locks
					waitingForXLock.t' = (waitingForXLock.t + txn->k)
														// ... the aborting transaction might be waiting for some other lock
														- (to_abort <: waitingForXLock.t)

				    started.t'					= started.t
				    read.t'						= read.t
					written.t' 					= written.t
				    committed.t'				= committed.t

					// Changes to bookeeping for SERIALIZABLE mode

					inConflict.t'					= inConflict.t - to_abort
					outConflict.t'					= outConflict.t - to_abort
					holdingSIREADlock.t'	= holdingSIREADlock.t - (to_abort <: holdingXLock.t)
					abortedToPreserveSerializability.t' = abortedToPreserveSerializability.t
				}
			}
		}
		else {
			// Here we know that txn won't cause a deadlock 
			// when it starts waiting for k's xlock.

			waitingForXLock.t' 	= waitingForXLock.t + txn->k

		    started.t'				= started.t
		    read.t'					= read.t
			written.t' 				= written.t
		    committed.t'			= committed.t
			aborted.t'				= aborted.t
			holdingXLock.t' 	= holdingXLock.t

			// SERIALIZABLE frame condition
			inConflict.t'					= inConflict.t
			outConflict.t'					= outConflict.t
			holdingSIREADlock.t'	= holdingSIREADlock.t
			abortedToPreserveSerializability.t' = abortedToPreserveSerializability.t
		}
	}
}

// Returns the set of all transactions that are involved in any cycle in the input graph.
fun txns_involved_in_cycle[waiting_for_held_by_with_cycle : TxnId->TxnId] : set TxnId {

	let txns_in_waiting_for_held_by 
		= TxnId.waiting_for_held_by_with_cycle + waiting_for_held_by_with_cycle.TxnId |

	{involved_in_cycle: txns_in_waiting_for_held_by | 
			no txn: TxnId | 
				txn in txn.^(waiting_for_held_by_with_cycle 
										- (involved_in_cycle->TxnId + TxnId->involved_in_cycle))
	}
}

// Helper for writes.
// This will abort txn if the write would violate serializability.
// If it does not abort then it both records that txn has acquired the xlock on k 
// and created a new version of k.
pred write_can_acquire_xlock[t, t': Time, txn: TxnId, k: Key] {

	/* From http://cahill.net.au/wp-content/uploads/2009/01/real-serializable.pdf

	get lock(key=x, locker=T, mode=WRITE)
	if there is a SIREAD lock(rl) on x with 
			 rl.owner is running 
	   	or commit(rl.owner) > begin(T): 
    {
		if rl.owner is committed and rl.owner.inConflict: {
			abort(T)
		}
		else {
			set rl.owner.outConflict = true
			set T.inConflict = true
		}
	}

	existing SI code for write(T, x, xNew)
	# do not get WRITE lock again
	*/

	// Note "get lock(key=x, locker=T, mode=WRITE)" is achieved by 
	// moving all of the code into this predicate (write_can_acquire_xlock), 
	// as this predicate is always called when we can unconditionally acquire the xlock.

	let concurrent_sireadlock_owners = concurrent_sireadlock_owners[t, txn, k] |

	some concurrent_sireadlock_owners => {
		// There are one or more other transactions that have overlapping lifetimes 
		// with txn, and which have read an earlier version of k than will/would 
		// be written by this write by txn.
		// 
		// i.e. If txn does this write, then it will create (or restate) one or more 
		// rw-dependencies in the conflict graph.  Specifically it will result in 
		// outConflicts from concurrent_sireadlock_owners to txn.

		// If one of the concurrent_sireadlock_ownersalready has an inConflict 
		// then this write could result in a 'dangerous structure' in the conflict 
		// graph (with that member of concurrent_sireadlock_owners as the pivot). 
		// If that potential pivot has already committed, then to ensure safety we 
		// must reject this write.
		// As mentioned earlier, we choose to do model the rejection of the write 
		// by aborting txn, rather than modelling a write-failure and allowing 
		// txn to continue with other operations.
		//
		(some sireadlock_owner : concurrent_sireadlock_owners | 
						sireadlock_owner in committed.t  
				and  sireadlock_owner in inConflict.t
		) => {
			// This write could potentially construct a 'dangerous structure' in the 
			// serializability graph.
			// To guarantee that we preserve serializability we need to abort one of 
			// the transactions that would be involved in that structure.
			// the other transaction that we know about (siread_lock_owner)
			// is already committed, so we have to abort.

			abort_to_preserve_serializability[t, t', txn]
		}
		else {
			// There are some concurrent_sireadlock_owners 
			// but this particular write will not immediately cause 
			// a dangerous structure to form with those other transactions.
			// So we can allow the write.

			si_do_write[t, t', txn, k]

			// Record the fact that all transactions in concurrent_sireadlock_owners 
			// now have an outbound rw-conflict (from themselves to txn).

			outConflict.t'	= outConflict.t + concurrent_sireadlock_owners

			// Record the fact that txn now has at least one inbound rw-conflict 
			// (from concurrent_sireadlock_owners to txn)

			inConflict.t'	= inConflict.t + txn

			// frame condition
			holdingSIREADlock.t' = holdingSIREADlock.t
			abortedToPreserveSerializability.t' = abortedToPreserveSerializability.t
		}
	}
	else {
		// Either k's SIREAD lock is not held, or all transactions that are holding it 
		// are not concurrent with txn.  
		// There's no risk that this write would form a 'dangerous structure' in 
		// the serializability graph, so it is safe to do this write.

		si_do_write[t, t', txn, k]

		// This write does not cause any transaction to become (more) involved 
		// in potential 'dangerous structures' in future.
		// So we just have a plain frame condition for the state that tracks that.
		inConflict.t'					= inConflict.t
		outConflict.t'					= outConflict.t
		holdingSIREADlock.t'	= holdingSIREADlock.t
		abortedToPreserveSerializability.t' = abortedToPreserveSerializability.t
	}
}

fun concurrent_sireadlock_owners[t: Time, txn: TxnId, k: Key] : set TxnId {

	/*
	if there is a SIREAD lock(rl) on x with 
			 rl.owner is running 
	   	or commit(rl.owner) > begin(T): 
	*/
	// Really means the set of all SIREAD lock owners (for k) 
	// that are concurrent with txn -- even if they have committed already.

	// NOTE: the paper doesn't mention whether the rl.owner can be txn.
	// I assume that the intent is to NOT include txn as a potential conflict with itself.

	{concurrent_SIREADlock_owner: (holdingSIREADlock.t).k - txn | 

				// "is running"		(if it were not in started.t or if it were in aborted.t, 
				// 						 then it would not be in holdingSIREADlock.t[k])
				(concurrent_SIREADlock_owner not in committed.t)   

				// or committed after txn started
			or TimeOrder/gt[time_of_commit[concurrent_SIREADlock_owner], 
									 time_of_start[txn]]
	}
}

pred si_do_write[t, t': Time, txn: TxnId, k: Key] {

	// Lock it and write it
	holdingXLock.t' 	= holdingXLock.t + txn->k
	written.t' 				= written.t + txn->k

	// In some circumstances, we are called when waitingForXLock.t 
	// shows that txn is waiting for k's xlock.
	// On exit, txn is always holding k's xlock, so it is always correct to remove 
	// any such entry from waitingForXLock.
	// As a transaction can only be waiting for one lock at a time (an invariant)
	// we can simply remove all of txn's entries from waitingForXLock.t.
	waitingForXLock.t'	= waitingForXLock.t - (txn <: waitingForXLock.t)

	// frame condition
    started.t'				= started.t
    read.t'					= read.t
    committed.t'			= committed.t
    aborted.t'				= aborted.t
}


// Internal operation (action)
pred finish_blocked_write[t, t': Time, txn: TxnId, k: Key] {

	// Enabling condition: txn is waiting for xlock on k, and k's xlock is nolonger held.
	(k in txn.waitingForXLock.t) and no (holdingXLock.t).k

	// We can now acquire k's xlock and do the write. 
	//
	// However, in serializable mode, the following predicate will abort txn if the write 
	// would violate serializability.
	// If it succeeds in doing the write then it both records that txn has acquired 
	// the xlock, and done (finished) the write.  
	// It also records that txn is nolonger waiting for k's xlock.

	write_can_acquire_xlock[t, t', txn, k]
}


pred commit[t, t': Time, txn: TxnId] {

	txn_started_and_can_do_public_operations[t, txn]

	/*
	if T.inConflict and T.outConflict: {
		abort(T)
	}
	existing SI code for commit(T)
	# release WRITE locks held by T
	# but do not release SIREAD locks
	*/

	(txn in inConflict.t)  and  (txn in outConflict.t) => {

		// This transaction has both an incoming rw-conflict and an out-going rw-conflict
		// so it is potentially part of a 'dangerous structure' in the conflict graph
		// (it would be the 'pivot' transaction').
		// To conservatively ensure safety, we must abort instead of committing.
		// Note; this is the unoptimized algorith from the sigmod paper. 
		// A real implementation would presumably abort this transaction earlier; 
		// as soon as it both its inConflict and outConflict flags become set.

		abort_to_preserve_serializability[t, t', txn]
	}
	else {

	    committed.t' = committed.t + txn

		// Obviously we also need to drop all xlocks that are held by txn.
		// That is done below, as we might need to drop locks held by loser_txns too.

		// We must enforce the FirstCommiterWins rule of Snapshot Isolation; 
		// If there are one or more transactions that 
		// are currently waiting for an xlock that is held by txn (the winner), 
		// then we must abort those loser transactions.

		let keys_xlocked_by_txn	= txn.holdingXLock.t,
			 loser_txns 				= (waitingForXLock.t).keys_xlocked_by_txn {

			// loser_txns might be empty, or contain any number of transactions.
			// The following works in any of those cases:

			// snapshot isolation doesn't have cascading aborts so we don't 
			// need to look transitively for the set of transactions to abort
			aborted.t'	= aborted.t + loser_txns

			// But we do need to drop all locks held by the loser transactions
			// and txn itself.
			// (This might unblock other transactions. That unblocking is modelled by 
			// other actions becoming enabled if a transaction that is in waitingForXLock
			// finds that the lock is nolonger held by anyone else.)
			holdingXLock.t' 	= holdingXLock.t - ((loser_txns + txn) <: holdingXLock.t)

			// And of course the aborted loser transactions are nolonger waiting for locks.
			// And neither is the winner txn.
			waitingForXLock.t' = waitingForXLock.t - (loser_txns <: waitingForXLock.t)

			// Book-keeping for serializable mode.
			// IMPORTANT; we do NOT remove txn from inConflict or outConflict,
			// and we do NOT release any SIREAD locks that txn holds.
			// But we do remove and release for any loser_txns.

			inConflict.t'					= inConflict.t - loser_txns
			outConflict.t'					= outConflict.t - loser_txns
			holdingSIREADlock.t'	= holdingSIREADlock.t - (loser_txns <: holdingSIREADlock.t)

			// frame condition
		    started.t'	= started.t
		    read.t'		= read.t
			written.t'	= written.t
			abortedToPreserveSerializability.t' = abortedToPreserveSerializability.t
		}
	}
}


// Abort by choice, or to avoid deadlock, or to preserve the SI FirstCommitterWins rule.
pred abort[t, t': Time, txn: TxnId] {
	internal_abort[t, t', txn]
	abortedToPreserveSerializability.t' = abortedToPreserveSerializability.t
}

// Abort only to avoid non-serializable histories.
// The only difference is that we track when this predicate is called, 
// to help find interesting instances for visualization.
pred abort_to_preserve_serializability[t, t': Time, txn: TxnId] {
	internal_abort[t, t', txn]
	abortedToPreserveSerializability.t' = abortedToPreserveSerializability.t + txn
}

// This helper does not constrain abortedToPreserveSerializability.t'
pred internal_abort[t, t': Time, txn: TxnId] {

	// Note; invoking  si_abort[] drags in txn_started_and_can_do_public_operations[t, txn]
	// as the enabling condition.  
	// That's what we want for a public operation, but we must make sure that 
	// any 'internal' attempts to abort (e.g. to avoid violations of serializability)
	// satisfy that enabling condition too -- otherwise the model will become over 
	// constrained, and will won't even attempt to check that kind of serializability violation.
	
	si_abort[t, t', txn]

	// Micahel Cahill's paper doesn't list the modifications for abort
	// but we assume we drop the SIREAD locks and lose the inConlict and outConflict flags.
	inConflict.t'					= inConflict.t - txn
	outConflict.t'					= outConflict.t - txn
	holdingSIREADlock.t'	= holdingSIREADlock.t - (txn <: holdingSIREADlock.t)
}

pred si_abort[t, t': Time, txn: TxnId] {

	txn_started_and_can_do_public_operations[t, txn]

    aborted.t' 				= aborted.t + txn
	holdingXLock.t' 		= holdingXLock.t - (txn <: holdingXLock.t) // drop all of txn's xlocks

	started.t'					= started.t
	read.t'						= read.t
	written.t'					= written.t
	committed.t'				= committed.t

	// as the enabling condition for abort[] includes txn_started_and_can_do_public_operations[t, txn]
	// then we know that txn cannot be waiting for xlock.
	// But in the more general case, aborting a txn should definitely cancel any waiting-for-xlock state, 
	// so we do that here. 
	waitingForXLock.t' 	= waitingForXLock.t - (txn <: waitingForXLock.t) 
}


pred skip[t,t': Time] {

	si_skip[t,t']	

	inConflict.t'					= inConflict.t
	outConflict.t'					= outConflict.t
	holdingSIREADlock.t'	= holdingSIREADlock.t
	abortedToPreserveSerializability.t' = abortedToPreserveSerializability.t
}

pred si_skip[t,t': Time] {
    started.t'					= started.t
    read.t'						= read.t
	written.t'					= written.t
    committed.t'				= committed.t
    aborted.t'					= aborted.t
	waitingForXLock.t' 	= waitingForXLock.t
	holdingXLock.t' 		= holdingXLock.t
}


// Facts for the execution-traces idiom 

pred init[t: Time] {

	si_init[t]

	no inConflict.t
	no outConflict.t
	no holdingSIREADlock.t
	no abortedToPreserveSerializability.t
}
pred si_init[t: Time] {
    no started.t
    no written.t
    no committed.t
    no read.t
    no aborted.t
	no waitingForXLock.t
	no holdingXLock.t
}

fact traces {

    init[TimeOrder/first[]]

    all t: Time - TimeOrder/last[] | let t' = TimeOrder/next[t] {

		// We allow (require) exactly one public operation (on a single transaction) 
		// per time-step.
		// However, some algorithm-specific constraints *might* also cause 
		// a simultaneous operation by one or more other transactions.
		// e.g. Attempting to commit a transaction might cause other transactions 
		// to abort.  
		// To follow standard literature for analyzing transaction concurrency control 
		// algorithms, we do desire that at most one read, write or commit 
		// occur at any point in time.  We have assertions that verify that condition.
		// If it ever matters that transactions are aborted in the same timestep 
		// as other operations, we can achieve that by introducing a 'pendingAbort' set,
		// and only enable abort[] steps for transactions that are in that set.

		// We allow (require) exactly one abstract operation per time-step
		some actiontxn: TxnId {

				// Public operations
				begin[t,t', actiontxn]

			or	( some actionkey: Key |
			        		read[t,t', actiontxn, actionkey]
					or		start_write_may_block[t, t', actiontxn, actionkey]
					or		finish_blocked_write[t, t', actiontxn, actionkey]
	        	)

            or commit[t, t', actiontxn]
            or abort[t, t', actiontxn]
			or skip[t,t']
        }
    }
}


//
// Analysis.
//
// Note that the Alloy Analyzer only executes the first 'run' or 'check' command that it finds 
// in the file.   We choose the command by commenting-out the ones we don't want to execute.
//

// Find an interesting instance
run {
	at_least_n_txn_abort_to_preserve_serializability[1]
} for 2 but 12 Time, 3 TxnId, 3 Key


// Full analysis
// This scope takes 559s With berkmin
//check { complete_analysis } for 2 but 15 Time, 4 TxnId, 3 Key

// berkmin takes 1062s on Dell 630 with 'for 2 but 13 Time, 3 TxnId, 2 Key '
// berkimin crashes with 'for 2 but 14 Time, 3 TxnId, 3 Key'
// minisat takes 139s on Dell 630 with '2 but 10 Time, 3 TxnId, 2 Key'
//check { basic_model_correctness } for 2 but 12 Time, 3 TxnId, 3 Key
	//check { safe_to_use_txnids_as_key_versionids } 
	//check { monotonically_growing_txn_state_sets } 
	//check { begin_is_always_first_action_of_txn } 
	//check { txn_at_most_one_commit_or_abort } 
	//check { commit_or_abort_can_only_be_final_action_of_txn } 
	//check { correctness_of_waitingForXLock } 
	//check { correct_concurrent_steps }
	//check { correctness_of_holdingXLock } 
	//check { correctness_of_abortedToPreserveSerializability[] }
	//for 2 but 14 Time, 4 TxnId, 3 Key	

    //check { semantics_of_snapshot_isolation } for 2 but 15 Time, 4 TxnId, 3 Key

	// If we intentionall break all_versionids_of_k_created_before_t_by_txns_committed_before_t
	// to allow uncommitted reads, this does detect them
	//check { txn_only_reads_from_latest_prior_committed_snapshot_or_itself } for 2 but 14 Time, 3 TxnId, 3 Key

	// This once found a bug in which
	//  t1 and t2 are concurrent and
	//  t1 writes to k and commits, and then t2 writes to k and also commits
	//  (was missing code to abort immediately if we attempt a write to a key that has 
	//  been modified and committed since we started)
	// berkmin; 354s
	//check { first_committer_wins } for 2 but 13 Time, 3 TxnId, 3 Key

	// This once found counter examples, when write[] did not detect & prevent deadlocks.
	// minisat: 406s
	// berkmin: crash
	//check { no_deadlock } for 2 but 13 Time, 4 TxnId, 3 Key

	// If we remove the deadlock-prevention code in write_conflicts_with_xlock[]
	// then this generates a deadlock graph-cycle containing 4 txns
	/*
	run { 
		some t: Time | 
			let waiting_for_held_by = (waitingForXLock.t).~(holdingXLock.t) |
				#{txn: TxnId | txn in txn.^waiting_for_held_by} > 3
	} for 5 but 15 Time, 4 TxnId, 4 Key
	*/

	//check { bernstein_serializable } for 2 but 13 Time, 3 TxnId, 2 Key

	// Berkmin: 1745s
	//check { cahill_serializable } for 2 but 14 Time, 4 TxnId, 3 Key

	// Confirm that our two slightly different phrasings of the serializability condition
	// are equivalent for all possible executions (in scope).
	//check { cahill_serializable <=> bernstein_serializable } for 2 but 15 Time, 4 TxnId, 3 Key

	// Confirm that our two slightly different phrasings of the serializability condition
	// are indeed not logically equivalent (not merely different styles of the same formula.)
	// This finds a counter-example
	//   T0 begins, writes k and commits, then 
	//   T1 begins, writes k and commits
	// cahill_mvsg has T0->T1 because of
	// 					(	// - T1 produces a version of x, and T2 produces a later version of x (this is a ww-dependency);
	// bernstein_mvsg is empty because
	//		not in bernstein_sg **as there is no read involved** and 
	//			"SG(H) has nodes for the committed transaction
	//			in H and edges Ti -> Tj (i /= j) whenever for some key x, Tj reads x from Ti.
	//			That is, Ti -> Tj is present iff for some x, rj[xi] (i /= j) is an operation of C(H).
	//		not in version_order_edges **as there is no read involved** 
	//		and version_order_edges requires an rk
	//			"for each rk[xj] and wi[xi] in C(H) where i, j, and k are distinct, 
	//	 		if xi << xj then include Ti -> Tj, 
	//			otherwise include Tk -> Ti. 
	//check { all t: Time | cahill_mvsg[t] = bernstein_mvsg[t] } for 2 but 7 Time, 2 TxnId, 1 Key


// visually check that 'not concurrent[]' forbids all concurrent transactions
//run { no disj t1, t2: TxnId | concurrent[t1,t2] } for 2 but 7 Time, 2 TxnId, 1 Key

/*
// Find a "read-only serializability anomaly" reported in Michael Cahill's thesis 
// (found by Fekete et al in an earlier paper)
//
// Berkmin takes 3153s to find the read-only serializability anomaly 
// for "for 5 but 14 Time, 4 TxnId, 3 Key" 
//
// minisat 1436s on Dell 630
run {
	some txn: TxnId | 
				txn in abortedToPreserveSerializability.TimeOrder/last[]
		and	#txn.read.(TimeOrder/last[]) = 2
		and	no txn.written.TimeOrder/last[]
		
} for 5 but 16 Time, 4 TxnId, 3 Key
*/


//
// Analysis assertions and predicates
//

pred complete_analysis[] {
	basic_model_correctness[]
	semantics_of_snapshot_isolation[]
}


pred basic_model_correctness[] {
	safe_to_use_txnids_as_key_versionids[]
	monotonically_growing_txn_state_sets[]
	begin_is_always_first_action_of_txn[]
	txn_at_most_one_commit_or_abort[]
	at_most_one_start_read_write_or_commit_per_timestep[]
	commit_or_abort_can_only_be_final_action_of_txn[]
	correctness_of_waitingForXLock[]
	correctness_of_holdingXLock[]
	correctness_of_abortedToPreserveSerializability[]
}

// Verify semantic properties of snapshot isolation
//
// 1. A txn may only ready from exactly the set of transactions that had been committed 
//	   at the time at which txn starts, or from writes done by txn itself 
//
// 2. First Committer Wins: if concurrent transactions write to intersecting sets of keys, 
//     then at most one of them can commit.
//
// 3. Deadlocks cannot be created.

pred semantics_of_snapshot_isolation {
	txn_only_reads_from_latest_prior_committed_snapshot_or_itself[]
	first_committer_wins[]
	no_deadlock[]
}


//
// Semantics of Snapshot Isolation
//

pred txn_only_reads_from_latest_prior_committed_snapshot_or_itself[] {

	// read is: ReaderTxnId -> Key -> VersionIdThatWasRead -> Time

	// check all transactions that did at least one read
	all txn_doing_read: ((read.Time).TxnId).Key {

		// for every transaction that txn_doing_read actually read from, *excluding* itself
		all txn_read_from: (txn_doing_read.read.Time[Key] - txn_doing_read) {

			// the read-from transaction must have committed
			// *before* the transaction doing the read even started.
			let time_of_read_from_commit = time_of_commit[txn_read_from] {
				some time_of_read_from_commit
				TimeOrder/lt[time_of_read_from_commit, time_of_start[txn_doing_read]]
			}
		}
	}
}


pred first_committer_wins[] {
	no disj t1, t2: TxnId |
				t1 in committed.Time
		and	t2 in committed.Time
		and	concurrent[t1,t2]
		and	some (t1.written.Time & t2.written.Time)  // intersecting sets of keys-written
}

// true iff both t1 and t2 start and their lifetimes overlap
pred concurrent[t1, t2: TxnId] {
	let 	t1_start		= time_of_start[t1],
			t1_finalize	= time_of_finalize[t1],
			t2_start		= time_of_start[t2],
			t2_finalize	= time_of_finalize[t2] {

				some t1_start
		&&	some t2_start
		&&	TimeOrder/lt[t1_start, t2_start] 								// t1 started before t2 started
					=> 	(		no t1_finalize 									// and (		t1 never finished
							or		TimeOrder/gt[t1_finalize, t2_start])	// 			or t1 finished after t2 started)
					else																	// t2 started before t1 started
							(		no t2_finalize										// and (		t1 never finished
							or		TimeOrder/gt[t2_finalize, t1_start])	// 			or t2 finished after t2 started)
	}
}

pred no_deadlock[] {
	// waitingForXLock: 	Txn->Key->Time
	// holdingXLock: 		Txn->Key->Time
	no t: Time | 
		let waiting_for_held_by = (waitingForXLock.t).~(holdingXLock.t) |
			some txn: TxnId | txn in txn.^waiting_for_held_by
}


//
// Verifying Serializability    
// [only here to find NON-serializable instances, until we implement Michael Cahill's algorithm for serializable-SI]
//
// We prove serializability by confirming that the MultiVersionSerializabilityGraph 
// is acyclic, for all histories constructed by the algorithm.

// I have two definitions of the MVSG at hand
//  - from Michael Cahill's PhD thesis on serializable snapshot isolation 
//  - From Phil Bernstein's book (the section on proving that MVTO is serializable)

// To check that I've implemented them correctly, I define both of them, 
// and then asssert that they are equivalent (imply other) at all times in all executions.


// From Michael Cahill's PhD thesis:
//
// Verifying that a history is conflict serializable is equivalent to showing that a particular graph is free of
// cycles. The graph that must be cycle-free contains a node for each transaction in the history, and an edge
// between each pair of conflicting transactions. Transactions T1 and T2 are said to conflict (or equivalently,
// to have a dependency) whenever they perform operations whose results reveal something about the order
// of the transactions; in particular when T1 performs an operation, and later T2 performs a conflicting
// operation. Operations O1 and O2 are said to conflict if swapping the order of their execution would
// produce different results (either a query producing a different answer, or updates producing different
// database state). A cycle in this graph implies that there is a set of transactions that cannot be executed
// serially in some order that gives the same results as in the original history.
// ...
// With snapshot isolation, the definitions of the serialization graph become much simpler, as versions of
// an item x are ordered according to the temporal sequence of the transactions that created those versions
// (note that First-Committer-Wins ensures that among two transactions that produce versions of x, one
// will commit before the other starts). 
//
// In the MVSG, we put an edge from one committed transaction T1
// to another committed transaction T2 in the following situations:
//
// - T1 produces a version of x, and T2 produces a later version of x (this is a ww-dependency);
// - T1 produces a version of x, and T2 reads this (or a later) version of x (this is a wr-dependency);
// - T1 reads a version of x, and T2 produces a later version of x (this is a rw-dependency, also
//        known as an anti-dependency, and is the only case where T1 and T2 can run concurrently).

pred cahill_serializable {

	all t: Time|
		no txn: TxnId | txn in txn.^(cahill_mvsg[t])
}

fun cahill_mvsg[t: Time] : TxnId->TxnId {

	{T1: committed.t, T2: committed.t |

			// from one committed transaction T1 to another [distinct] committed transaction T2 
					T1 != T2

			and	some x: Key {
					(	// - T1 produces a version of x, and T2 produces a later version of x (this is a ww-dependency);
								x in T1.written.t
						and 	x in T2.written.t
						and	TxnIdOrder/gt[T2, T1]
					)
				or	(	// - T1 produces a version of x, and T2 reads this (or a later) version of x (this is a wr-dependency);
								x in T1.written.t
						and 	some read_versionid: TxnId {
										// read is ReaderTxnId -> Key -> VersionIdThatWasRead -> Time
										read_versionid in T2.read.t[x]
								and	TxnIdOrder/gte[read_versionid, T1]
						}
					)
				or	(	// - T1 reads a version of x, and T2 produces a later version of x (this is a rw-dependency, also
						//        known as an anti-dependency, and is the only case where T1 and T2 can run concurrently).
						some read_versionid: TxnId {
							// read is ReaderTxnId -> Key -> VersionIdThatWasRead -> Time
									read_versionid in T1.read.t[x]
							and	x in T2.written.t
							and	TxnIdOrder/gt[T2, read_versionid]
						}
					)
				}
	}

}


// From Phil Bernstein's book
//
// This is the correctness condition from p152 (chapter 5 section 5.2) of Bernstein's book:
//
//		Theorem 5.4: An MV history H is 1SR iff there exists a version order, <<, 
//		such that MVSG(H, <<) is acyclic.
//
//
// 'version order' is defined as:	
//
// 	// From p151
//	Given an MV history H and a data item [key] x, a version order, <, for x in H is
//	a total order of versions of x in H. 
//	A version order, <<, for H is the union of the version orders for all data items. 
// For example, a possible version order for H, is x0 << x2, y0 << y1 << y3.
//
//
// The version order is defined (for MVTO) as:
//
// From p152
//	Given an MV history H and a version order, <<, the multiversion serialization
//	graph for H and <<, MVSG(H, <<), is SG(H) with the following version
//	order edges added: for each rk[xj] and wi[xi] in C(H) where i, j, and k are
//	distinct, if xi << xj then include Ti -> Tj, otherwise include Tk -> Ti. 
//	Recall that the nodes of SG(H) and, therefore, of MVSG(H, <<) are the 
// committed transactions in H.
//	(Note that there is no version order edge if j = k, that is, if a transaction reads 
// from itself.)
//
//
// SG(H) is defined as follows:
//
// From p149:
// 	The serialization graph for an MV history is defined as for a 1V history.
//
// From p32  (section 2.3, serializability theory for monoversion histories)	
//	The serialization graph (SG) for H, denoted SG(H), is a directed
//	graph whose nodes are the transactions in T that are committed in H and
//	whose edges are all Ti -> Tj (i =/ j) such that one of Ti's operations precedes
//	and conflicts with one of Tj's operations in H.
//
// Continuing p149
// 	But since only one kind of conflict is possible in an MV history, SGs are quite
// 	simple. Let H be an MV history. SG(H) has nodes for the committed transaction
// 	in H and edges Ti -> Tj (i /= j) whenever for some key x, Tj reads x from Ti.
// 	That is, Ti -> Tj is present iff for some x, rj[xi] (i /= j) is an operation of C(H).
//
// From p30
//	Given a history H, the committed projection of H, denoted C(H), is the history 
// 	obtained from H by deleting all operations that do not belong to transactions 
// committed in H.  Note that C(H) is a complete history over the set of committed 
// transactions in H. If H represents an execution at some point in time, C(H) is the 
// only part of the execution we can count on, since active transactions can be 
// aborted at any time, for instance, in the event of a system failure.

pred bernstein_serializable {

	// MVSG[H, <<] is acyclic
	// i.e. No node (TxnId) can be reached by starting at that node and following 
	// a directed path in the graph.
	// i.e. No node can be reached from itself in the transitive closure of MVSG[H, <<]

	all t: Time|
		no txn: TxnId | txn in txn.^(bernstein_mvsg[t])

	// TODO: is this faster to check?
	// 			no (iden & ^(mvsg[t]))
	//
	// (Actually, avoiding the set-comprehensions in version_order_edges[] 
	// might have more impact on speed.
}

fun bernstein_mvsg[t: Time] : TxnId->TxnId {
	bernstein_sg[t] + bernstein_version_order_edges[t]
}

// SG(H)
// "Ti -> Tj is present iff for some x, rj[xi] (i /= j) is an operation of C(H).
//
// We confine the result to C(H) by only considering Ti, Tj, Tk that are in committed.t
fun bernstein_sg[t: Time] : TxnId->TxnId {

	{writer_txn: committed.t, reader_txn: committed.t | 
					reader_txn != writer_txn						// distinct
			and	writer_txn in reader_txn.read.t[Key]	// reader read from writer
	}
}

//	"for each rk[xj] and wi[xi] in C(H) where i, j, and k are distinct, 
//	 if xi << xj then include Ti -> Tj, 
//		otherwise include Tk -> Ti. 
//
// We confine the result to C(H) by only considering Ti, Tj, Tk that are in committed.t
fun bernstein_version_order_edges[t: Time] : TxnId->TxnId {

	{Ti: committed.t, Tj: committed.t | 
				Ti != Tj  					// Ti and Tj are distinct committed transactions
		and	some Tk : committed.t |
						Tk != Ti				// Tk is a committed transaction distinct from Ti and Tj
				and	Tk != Tj
				and 	some x: Key |
							Tj in Tk.read.t[x]			// rk[xj] is in C(H)  (Tj is in set of transactions that Tk read from)
					and	x in Ti.written.t				// xi exists in C(H)
					and 	x in Tj.written.t				// xj exists in C(H)
					and	TxnIdOrder/lt[Ti, Tj]}	// xi << xj  (as version order is TxnId order)
	+	
	{Tk: committed.t, Ti: committed.t | 
				Tk != Ti  					// Tk and Ti are distinct
		and	some Tj : committed.t |
						Tj != Tk				// Tj is distinct from Ti and Tj
				and	Tj != Ti
				and 	some x: Key |
							Tj in Tk.read.t[x]	 		// rk[xj] is in C(H)  (Tj is in set of transactions that Tk read from)
					and 	x in Ti.written.t					// xi exists in C(H)
					and 	x in Tj.written.t					// xj exists in C(H)
					and	not TxnIdOrder/lt[Ti, Tj]}	// NOT xi << xj  (as version order is TxnId order)
}


//
// Basic model correctness
//

pred safe_to_use_txnids_as_key_versionids[] {
	// For each key, the versionid order of committed writes matches the temporal order of 
	// committed writes.
	// i.e. No version is ever commmitted that has a lower version-id than an existing 
	// committed version.
	// The mechanism that enforces this is 
	//   1. the First committer Wins Rule; if more than one concurrent transaction 
	//		 writes to a key, at most one can commit.  
	//   2. The artificial constraint that for this model, transactions always 
	//       begin in order of TxnId.
	// Therefore all successful writes (i.e. committed writes) to a key must be done 
	// by transactions with increasing TxnIds.
	// i.e. Transactions commit in TxnId order.

	// ... for all pairs of different transactions that have both written and committed
	// ... written is WriterTxnId -> Key -> Time

	all k: Key | 
		all disj txn1, txn2 : (written.Time).k & committed.Time | 
			let		t1c = time_of_commit[txn1],
					t2c = time_of_commit[txn2] |

						TxnIdOrder/lt[txn1,txn2]   iff  TimeOrder/lt[t1c, t2c]
				and	TxnIdOrder/gt[txn1,txn2]  iff  TimeOrder/gt[t1c, t2c]
}
	
// This verifies that frame conditions are complete (i.e. don't accidentally allow spurious changes)
pred monotonically_growing_txn_state_sets[] {
	monotonically_growing_txn_state_set[started]
	monotonically_growing_txn_state_set[committed]
	monotonically_growing_txn_state_set[aborted]
	all t: Time - TimeOrder/last[] {
		read.t in read.(TimeOrder/next[t])
		written.t in written.(TimeOrder/next[t])
	}
}

pred monotonically_growing_txn_state_set[s: TxnId->Time] {
	all t: Time - TimeOrder/last[] |
		s.t in s.(TimeOrder/next[t])
}

// If a transaction starts at all, then start is the first operation in that txn
pred begin_is_always_first_action_of_txn[] {
	all txn: TxnId |
		some txn.started => 
			time_of_start[txn] = TimeOrder/min[times_of_all_events[txn]] 
}

// A transaction can do at most one commit or abort. 
// (can't commit or abort multlple times, and can't both commit and abort)
pred txn_at_most_one_commit_or_abort[] {
	all txn: TxnId |  lone time_of_finalize[txn]
}

// If a transaction commits or aborts then that commit or abort is the last operation 
// of that transaction
pred commit_or_abort_can_only_be_final_action_of_txn[] {
	all txn: TxnId |
		let time_of_finalize = time_of_finalize[txn] |
		some time_of_finalize => 
			time_of_finalize = TimeOrder/max[times_of_all_events[txn]]
}

pred correctness_of_abortedToPreserveSerializability[] {
	monotonically_growing_txn_state_set[abortedToPreserveSerializability]
	all txn: TxnId |
		some time_of_abort_to_preserve_serializability[txn] =>
			time_of_abort_to_preserve_serializability[txn] = time_of_abort[txn]
}

pred correctness_of_waitingForXLock[] {
	// A transaction can only be waiting for one xlock at any point in time
	all txn: TxnId | all t: Time | lone txn.waitingForXLock.t

	//	A transaction cannot begin to wait for a particular xlock (i.e. particular key) 
	// more than once
	all txn: TxnId | all k: Key | lone k.(start_wait_for_xlock_events[txn])

	// A transaction might wait for different xlocks at different times
	// We can't assert this as it is not true for all executions.
	// I'd like to assert that it is true for some executions (i.e. not prohibited 
	// by the model).  But the best way to check that is probably to 
	// 'run' it to find and visually inspect an instance.
	//		some txn: TxnId | #(wait_for_xlock_events[txn]) > 1

	// Every time a transaction leaves the waitingForXLock state, 
	// it does so either  by acquiring that particular lock or aborting
	all txn: TxnId |
		let swle = stop_wait_for_xlock_events[txn] |
			all k: swle.Time | let post_t = k.swle |
						k->post_t in acquire_xlock_events[txn]
				or		post_t = time_of_abort[txn]

	// Multiple transactions can be waiting for the same lock (and different locks)
	// We can't assert this as it is not true for all executions.
	// I'd like to assert that it is true for some executions (i.e. not prohibited 
	// by the model).  But the best way to check that is probably to 
	// 'run' it to find and visually inspect an instance.
	//		some t:Time | some k: Key | waitingForXLock.t[k] > 1
}

pred at_most_one_start_read_write_or_commit_per_timestep[] {
	// (It's not true that exactly one action happens in every step, because
	// some actions can force other transactions to abort in the same step.)

	// read:		ReaderTxnId -> Key -> VersionIdThatWasRead -> Time
	// written:	WriterTxnId -> Key -> Time

	all t: Time - TimeOrder/first[] {
		let p = TimeOrder/prev[t], 

			 s = started.t - started.p, 
			 r = read.t - read.p, 
			 w = written.t - written.p,
			 c = committed.t - committed.p {

			lone s
			lone r
			lone w
			lone c
			some s => (no r and no w and no c)
			some r => (no s and no w and no c)
			some w => (no s and no r and no c)
			some c => (no s and no r and no w)
		}
	}
}

pred correctness_of_holdingXLock[] {
	// - no two transactions can hold the same xlock at the same time
	// holding_for_xlock is HolderTxnId->Key->Time
	all t: Time | all k: Key | lone (holdingXLock.t).k

	// If a transaction is finalized then all of the txn's locks are continuously held 
	// from time of acquisition until time of finalize (are released in the same transition as finalize).
	// If a transaction is not finalized, then its locks are never released.
	all txn: TxnId |
		some time_of_finalize[txn] => {
			all k: (acquire_xlock_events[txn]).Time | 
				k.(release_xlock_events[txn]) = time_of_finalize[txn]
		}
		else {
			no release_xlock_events[txn]
		}

	// All writes are done while holding the appropriate xlock
	// (This doesn't check that at most one write is done per time-step;
	// that is checked elsewhere.)
	all t: Time - TimeOrder/last[] | let p = TimeOrder/prev[t] |
 		all k: Key | 
			all txn: TxnId |
				txn in (written.t).k and txn not in (written.p).k 
					=> txn in (holdingXLock.t).k

	// A transaction can hold multiple locks at the same time
	// We can't assert this as it is not true for all executions.
	// I'd like to assert that it is true for some executions (i.e. not prohibited 
	// by the model).  But the best way to check that is probably to 
	// 'run' it to find and visually inspect an instance.
	//	some txn: TxnId | txn.holding_for_xlock.t[Key] > 1
}


//
// Helpers
//

// These return an empty set if the transaction never did any event(s) of
// the specified type

// All 'event times' are the time of the POST state of the event (i.e. when the 
// state change corresponding to the event first showed up).

fun time_of_start[txn: TxnId] : lone Time {
	time_of_simple_event[txn, started]
}

fun read_events[txn: TxnId] : Key->TxnId->Time {
	{k: Key, versionid: TxnId, post_t: Time - TimeOrder/first[] | 
					k->versionid not in txn.read.(TimeOrder/prev[post_t])
			and	k->versionid in txn.read.post_t}
}

fun start_wait_for_xlock_events[txn: TxnId] : Key->Time {
	{k: Key, post_t: Time - TimeOrder/first[] | 
					k not in txn.waitingForXLock.(TimeOrder/prev[post_t])
			and	k in txn.waitingForXLock.post_t}
}

fun stop_wait_for_xlock_events[txn: TxnId] : Key->Time {
	{k: Key, post_t: Time - TimeOrder/first[] | 
					k in txn.waitingForXLock.(TimeOrder/prev[post_t])
			and	k not in txn.waitingForXLock.post_t}
}

fun acquire_xlock_events[txn: TxnId] : Key->Time {
	{k: Key, post_t: Time - TimeOrder/first[] | 
					k not in txn.holdingXLock.(TimeOrder/prev[post_t])
			and	k in txn.holdingXLock.post_t}
}

fun release_xlock_events[txn: TxnId] : Key->Time {
	{k: Key, post_t: Time - TimeOrder/first[] | 
					k in txn.holdingXLock.(TimeOrder/prev[post_t])
			and	k not in txn.holdingXLock.post_t}
}

fun write_events[txn: TxnId] : Key->Time {
	{k: Key, post_t: Time - TimeOrder/first[] | 
					k not in txn.written.(TimeOrder/prev[post_t])
			and	k in txn.written.post_t}
}

fun time_of_commit[txn: TxnId] : lone Time {
	time_of_simple_event[txn, committed]
}

fun time_of_abort[txn: TxnId] : lone Time {
	time_of_simple_event[txn, aborted]
}

fun time_of_abort_to_preserve_serializability[txn: TxnId] : lone Time {
	time_of_simple_event[txn, abortedToPreserveSerializability]
}

fun time_of_finalize[txn: TxnId] : lone Time {
	time_of_commit[txn] + time_of_abort[txn]
}

fun time_of_simple_event[txn: TxnId, r: TxnId->Time] : lone Time {
	{post_t: Time - TimeOrder/first[] |
					txn not in r.(TimeOrder/prev[post_t])
			and	txn in r.post_t}
}

fun times_of_all_events[txn: TxnId] : set Time {
		time_of_start[txn]
		// read_events returns a set of   Key->VersionIdRead->TimeOfEvent
	+	((read_events[txn])[Key])[TxnId]	
		// write_events returns a set of   Key->TimeOfEvent
	+	write_events[txn][Key]
		// *_xlock_events returns a set of Key->TimeOfEvent
	+ start_wait_for_xlock_events[txn][Key]
	+ stop_wait_for_xlock_events[txn][Key]
	+ acquire_xlock_events[txn][Key]
	+ release_xlock_events[txn][Key]
	+ time_of_finalize[txn]
}

//
// Ad-hoc constraints, pulled into other predicates purely to select interesting instances.
//

pred all_txns_must_start[] {
	TxnId in started.Time
}
pred all_txns_do_at_least_one_read_or_write[] {
	// read is: 		ReaderTxnId -> KeyThatWasRead -> VersionIdThatWasRead -> Time
	// written is: 	WriterTxnId -> KeyThatWasWritten -> Time
    	(TxnId in (read.Time.TxnId).Key)
	or	(TxnId in (written.Time).Key)
}
pred some_txn_reads_from_another[] {
	some disj Ti,Tj : TxnId | Ti in (Tj.read.Time)[Key]
}
pred no_txn_reads_from_itself[] {
	no Ti : TxnId | Ti in (Ti.read.Time)[Key]
}
pred at_least_one_txn_does_a_write[] {
	#written.Time > 0
}
pred at_least_one_txn_does_a_read[] {
	#read.Time > 0
}
pred if_any_txn_writes_it_does_not_read[] {
	all txn: TxnId | some txn.written => no txn.read
}
pred at_least_one_txn_waits_for_an_xlock_and_commits[] {
	some txn: TxnId | 
				some start_wait_for_xlock_events[txn] 
		and	some time_of_commit[txn]
}
pred all_txns_commit_or_abort[] {
	TxnId in (committed.Time + aborted.Time)
}
pred no_txns_abort[] {
	no aborted.Time
}
pred at_least_one_txn_aborts[] {
	#aborted.Time > 0
}
pred at_least_n_txn_abort_to_preserve_serializability[n: Int] {
	#(abortedToPreserveSerializability.TimeOrder/last[]) >= n
}


// TODO: check that the model is not now over-constrained
//	 by changing the algorithm to intentional violate a correctness property, and confirm that the expected violations are found

