module remembramark-brevis-circuits

go 1.21

require (
	github.com/brevis-network/brevis-sdk v0.0.0
	github.com/ethereum/go-ethereum v1.13.0
)

// Using local brevis-sdk clone from ../lib/brevis-sdk
// This ensures version consistency with cloned repository
replace github.com/brevis-network/brevis-sdk => ../lib/brevis-sdk
