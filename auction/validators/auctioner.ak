use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use aiken/interval.{Finite}
use auction/types.{AuctionerDatum, AuctionerRedeemer, PosixTime}
use cardano/address.{VerificationKey}
use cardano/assets.{Value}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, ValidityRange,
}

/// The Auction Validator
///
/// Actions:
/// - 0: Cancel Auction - Tx2
/// - 1: PlaceBid - Tx3, Tx4
/// - 2: Payout, Tx5
validator auctioner {
  spend(
    auction_datum: Option<AuctionerDatum>,
    user_action: AuctionerRedeemer,
    target_output_ref: OutputReference,
    tx_info: Transaction,
  ) {
    // trace @"auction_datum": auction_datum
    expect Some(auction_state) = auction_datum

    when user_action.action is {
      // Cancel Auction
      0 -> and {
          theres_no_bid(auction_state)?,
          nft_to_seller(auction_state, target_output_ref, tx_info)?,
        }

      // PlaceBid:
      1 -> and {
          before_deadline(tx_info.validity_range, auction_state.end_time)?,
          when auction_state.current_bid is {
            // If first bid, must be at least min big specified in config:
            0 -> (user_action.bid >= auction_state.min_bid)?

            _ -> and {
                // new bid is at least 1% higher than previous high:
                (user_action.bid >= auction_state.current_bid + auction_state.current_bid / 100)?,
                // refunds the previous bidder:
                refunds_previous(
                  tx_info.outputs,
                  auction_state,
                  user_action.bid,
                  user_action.bidder_vkh,
                )?,
                // includes correct continuing output:
                valid_cont_output(
                  target_output_ref,
                  tx_info,
                  assets.from_asset(
                    auction_state.asset_value.1st,
                    auction_state.asset_value.2nd,
                    auction_state.asset_value.3rd,
                  ),
                  user_action.bid,
                  user_action.bidder_vkh,
                )?,
              }
          },
        }

      // PayOut:
      2 -> and {
          // End time has passed:
          !before_deadline(tx_info.validity_range, auction_state.end_time)?,
          // Pays to the seller:
          pays_seller(tx_info.outputs, auction_state)?,
          // Pays the asset to high bidder:
          pays_asset_value(
            tx_info.outputs,
            assets.from_asset(
              auction_state.asset_value.1st,
              auction_state.asset_value.2nd,
              auction_state.asset_value.3rd,
            ),
            auction_state,
          )?,
        }

      // Otherwise:
      _ -> False
    }
  }

  else(_) {
    fail
  }
}

fn theres_no_bid(auction_state: AuctionerDatum) -> Bool {
  auction_state.current_bid == 0
}

fn nft_to_seller(
  datum: AuctionerDatum,
  target_utxo: OutputReference,
  tx_info: Transaction,
) -> Bool {
  // find input's utxo data
  let input_utxo = find_validating_input(target_utxo, tx_info)

  // Checking the NFT in the input UTxO
  let check_input_nft =
    fn() {
      let in_qty =
        input_utxo.output.value
          |> assets.quantity_of(datum.asset_value.1st, datum.asset_value.2nd)
      (in_qty == 1)?
    }

  // Checking the NFT in the output UTxO
  let check_output_nft =
    fn() {
      let nft_to_seller_output = {
        let utxo <- list.filter(tx_info.outputs)
        let nft_qty =
          utxo.value
            |> assets.quantity_of(datum.asset_value.1st, datum.asset_value.2nd)
        and {
          nft_qty == 1,
          utxo.address.payment_credential == VerificationKey(datum.seller_vkh),
        }
      }
      let out_count =
        nft_to_seller_output
          |> list.length
      (out_count == 1)?
    }

  and {
    check_input_nft()?,
    check_output_nft()?,
  }
}

fn pays_value(
  receiver_vkh: VerificationKeyHash,
  target_value: Value,
  outputs: List<Output>,
) -> Bool {
  // Look for a matching output that satisfies the helper
  let out: Output <- list.any(outputs)
  and {
    (out.address.payment_credential == VerificationKey(receiver_vkh))?,
    (assets.without_lovelace(out.value) == assets.without_lovelace(target_value))?,
    (assets.lovelace_of(out.value) >= assets.lovelace_of(target_value))?,
  }
}

fn pays_ada(
  bid_amt: Int,
  outputs: List<Output>,
  receiver_vkh: VerificationKeyHash,
) -> Bool {
  let bid_val = assets.from_lovelace(bid_amt)
  pays_value(receiver_vkh, bid_val, outputs)?
}

fn refunds_previous(
  outputs: List<Output>,
  bid_state: AuctionerDatum,
  bid: Int,
  bidder_vkh: VerificationKeyHash,
) -> Bool {
  when bid_state.current_bid is {
    0 -> True
    _ -> pays_ada(bid, outputs, bidder_vkh)?
  }
}

fn pays_seller(outputs: List<Output>, bid_state: AuctionerDatum) -> Bool {
  when bid_state.current_bid is {
    0 -> True
    _ -> pays_ada(bid_state.current_bid, outputs, bid_state.seller_vkh)
  }
}

fn pays_asset_value(
  outputs: List<Output>,
  asset_value: Value,
  // from_asset(policy_id: PolicyId, asset_name: AssetName, quantity: Int) -> Value
  bid_state: AuctionerDatum,
) -> Bool {
  let recipient_vkh =
    when bid_state.current_bid is {
      0 -> bid_state.seller_vkh
      // If no bid, pay asset to seller
      // If bid, pay asset to current high bidder
      _ -> bid_state.bidder_vkh
    }
  pays_value(recipient_vkh, asset_value, outputs)
}

fn find_validating_input(
  target_output_ref: OutputReference,
  tx_info: Transaction,
) -> Input {
  expect Some(input) = transaction.find_input(tx_info.inputs, target_output_ref)

  // Now return the input:
  input
}

fn get_continuing_outputs(
  target_output_ref: OutputReference,
  tx_info: Transaction,
) -> List<Output> {
  let input = find_validating_input(target_output_ref, tx_info)
  let script_address = input.output.address

  // Back-passing:
  let out: Output <- list.filter(tx_info.outputs)
  out.address == script_address
}

fn valid_cont_output(
  target_output_ref: OutputReference,
  tx_info: Transaction,
  target_value: Value,
  target_bid: Int,
  target_bidder_vkh: VerificationKeyHash,
) -> Bool {
  expect [cont_output] = get_continuing_outputs(target_output_ref, tx_info)

  let output_contains_nft =
    fn() {
      assets.without_lovelace(cont_output.value) == assets.without_lovelace(
        target_value,
      )
    }
  let output_contains_at_least_lovelace =
    fn() { assets.lovelace_of(cont_output.value) >= target_bid }

  // check correct continuing output value
  if and {
    output_contains_nft()?,
    output_contains_at_least_lovelace()?,
  } {
    // check correct continuing output datum
    // trace @"cont_output.datum": cont_output.datum
    expect InlineDatum(new_auction_state) = cont_output.datum
    // trace @"new_auction_state": new_auction_state
    expect the_datum: AuctionerDatum = new_auction_state

    and {
      (the_datum.bidder_vkh == target_bidder_vkh)?,
      (the_datum.current_bid == target_bid)?,
    }
  } else {
    // wrong value!
    False
  }
}

fn before_deadline(range: ValidityRange, deadline: PosixTime) -> Bool {
  when range.lower_bound.bound_type is {
    Finite(now) -> {
      trace @"Finite interval": now, deadline
      (now < deadline)?
    }

    _ -> {
      trace @"Non-finite interval"
      False
    }
  }
}
