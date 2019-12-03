package tss

import (
	"fmt"
	"math/big"
	"time"

	"github.com/binance-chain/tss-lib/ecdsa/keygen"
	"github.com/binance-chain/tss-lib/tss"
	"github.com/ipfs/go-log"
	"github.com/keep-network/keep-core/pkg/beacon/relay/group"
	"github.com/keep-network/keep-tecdsa/pkg/net"
)

const preParamsGenerationTimeout = 90 * time.Second

var logger = log.Logger("keep-ecdsa")

// GenerateTSSPreParams calculates parameters required by TSS key generation.
// It times out after 90 seconds if the required parameters could not be generated.
// It is possible to generate the parameters way ahead of the TSS protocol
// execution.
// TODO: Consider pre-generating parameters to a pool and use them on protocol
// start.
func GenerateTSSPreParams() (*keygen.LocalPreParams, error) {
	preParams, err := keygen.GeneratePreParams(preParamsGenerationTimeout)
	if err != nil {
		return nil, fmt.Errorf("failed to generate tss pre-params: [%v]", err)
	}

	return preParams, nil
}

// InitializeSigner initializes a member to run a threshold multi-party key
// generation protocol.
//
// It expects unique indices of members in the signing group as well as a group
// size to produce a unique members identifiers.
//
// TSS protocol requires pre-parameters such as safe primes to be generated for
// execution. The parameters should be generated prior to initializing the signer.
//
// Network provider needs to support broadcast and unicast transport.
func InitializeSigner(
	memberIndex group.MemberIndex,
	groupSize int,
	threshold int,
	tssPreParams *keygen.LocalPreParams,
	networkProvider net.Provider,
) (*Signer, error) {
	if memberIndex <= 0 {
		return nil, fmt.Errorf("member index must be greater than 0")
	}

	thisPartyID, groupPartiesIDs := generateGroupPartiesIDs(memberIndex, groupSize)

	errChan := make(chan error)

	keyGenParty, params, endChan := initializeKeyGenerationParty(
		thisPartyID,
		groupPartiesIDs,
		threshold,
		tssPreParams,
		networkProvider,
		errChan,
	)
	logger.Debugf("initialized key generation party: [%v]", keyGenParty.PartyID())

	signer := &Signer{
		tssParameters:   params,
		keygenParty:     keyGenParty,
		networkProvider: networkProvider,
		keygenEndChan:   endChan,
		keygenErrChan:   errChan,
	}

	return signer, nil
}

// GenerateKey executes the protocol to generate a signing key. This function
// needs to be executed only after all members finished the initialization stage.
// As a result the signer will be updated with the key generation data.
func (s *Signer) GenerateKey() error {
	defer unregisterRecv(
		s.networkProvider,
		s.keygenParty,
		s.tssParameters,
		s.keygenErrChan,
	)

	if err := s.keygenParty.Start(); err != nil {
		return fmt.Errorf(
			"failed to start key generation: [%v]",
			s.keygenParty.WrapError(err),
		)
	}

	for {
		select {
		case s.keygenData = <-s.keygenEndChan:
			return nil
		case err := <-s.keygenErrChan:
			return fmt.Errorf(
				"failed to generate signer key: [%v]",
				s.keygenParty.WrapError(err),
			)
		}
	}
}

func generateGroupPartiesIDs(
	memberIndex group.MemberIndex,
	groupSize int,
) (*tss.PartyID, []*tss.PartyID) {
	var thisPartyID *tss.PartyID
	groupPartiesIDs := []*tss.PartyID{}

	for i := 1; i <= groupSize; i++ {
		newPartyID := tss.NewPartyID(
			string(i),            // id - unique string representing this party in the network
			"",                   // moniker - can be anything (even left blank)
			big.NewInt(int64(i)), // key - unique identifying key
		)

		if memberIndex.Equals(i) {
			thisPartyID = newPartyID
		}

		groupPartiesIDs = append(groupPartiesIDs, newPartyID)
	}

	return thisPartyID, groupPartiesIDs
}

func initializeKeyGenerationParty(
	currentPartyID *tss.PartyID,
	groupPartiesIDs []*tss.PartyID,
	threshold int,
	tssPreParams *keygen.LocalPreParams,
	networkProvider net.Provider,
	errChan chan error,
) (tss.Party, *tss.Parameters, <-chan keygen.LocalPartySaveData) {
	outChan := make(chan tss.Message)
	endChan := make(chan keygen.LocalPartySaveData)

	ctx := tss.NewPeerContext(tss.SortPartyIDs(groupPartiesIDs))
	params := tss.NewParameters(ctx, currentPartyID, len(groupPartiesIDs), threshold)
	party := keygen.NewLocalParty(params, outChan, endChan, *tssPreParams)

	go bridgeNetwork(
		networkProvider,
		outChan,
		endChan,
		errChan,
		party,
		params,
	)

	return party, params, endChan
}
