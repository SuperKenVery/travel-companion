//! One-to-one call signaling and connection state machine. Audio and CallKit
//! remain in the platform capability module.

use serde::{Deserialize, Serialize};
use tc_model::{CallId, PeerId};
use thiserror::Error;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CallEndReason {
    LocalEnded,
    RemoteEnded,
    Rejected,
    Busy,
    OfferExpired,
    ConnectionLost,
    AudioInterrupted,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "phase")]
pub enum CallState {
    Idle,
    Outgoing {
        call_id: CallId,
        peer_id: PeerId,
        offered_at_ms: i64,
        expires_at_ms: i64,
    },
    Incoming {
        call_id: CallId,
        peer_id: PeerId,
        offered_at_ms: i64,
        expires_at_ms: i64,
    },
    Connecting {
        call_id: CallId,
        peer_id: PeerId,
    },
    Active {
        call_id: CallId,
        peer_id: PeerId,
        connected_at_ms: i64,
    },
    Reconnecting {
        call_id: CallId,
        peer_id: PeerId,
        deadline_ms: i64,
    },
    Ended {
        call_id: CallId,
        peer_id: PeerId,
        reason: CallEndReason,
        ended_at_ms: i64,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum CallSignal {
    Offer {
        call_id: CallId,
        caller_id: PeerId,
        callee_id: PeerId,
        expires_at_ms: i64,
    },
    Answer {
        call_id: CallId,
    },
    Reject {
        call_id: CallId,
        reason: CallEndReason,
    },
    End {
        call_id: CallId,
        reason: CallEndReason,
    },
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum CallError {
    #[error("call action is invalid in the current state")]
    InvalidState,
    #[error("signal belongs to a different call")]
    WrongCall,
    #[error("call offer has expired")]
    Expired,
}

#[derive(Clone, Debug)]
pub struct CallMachine {
    local_peer: PeerId,
    state: CallState,
}

impl CallMachine {
    #[must_use]
    pub fn new(local_peer: PeerId) -> Self {
        Self {
            local_peer,
            state: CallState::Idle,
        }
    }

    #[must_use]
    pub fn state(&self) -> &CallState {
        &self.state
    }

    pub fn start(
        &mut self,
        peer_id: PeerId,
        now_ms: i64,
        offer_ttl_ms: i64,
    ) -> Result<CallSignal, CallError> {
        if !matches!(self.state, CallState::Idle | CallState::Ended { .. }) {
            return Err(CallError::InvalidState);
        }
        let call_id = CallId::new();
        let expires_at_ms = now_ms.saturating_add(offer_ttl_ms);
        self.state = CallState::Outgoing {
            call_id: call_id.clone(),
            peer_id: peer_id.clone(),
            offered_at_ms: now_ms,
            expires_at_ms,
        };
        Ok(CallSignal::Offer {
            call_id,
            caller_id: self.local_peer.clone(),
            callee_id: peer_id,
            expires_at_ms,
        })
    }

    /// Handles offer glare deterministically: the lexicographically smaller
    /// call id wins on both devices.
    pub fn receive_offer(
        &mut self,
        call_id: CallId,
        caller_id: PeerId,
        offered_at_ms: i64,
        expires_at_ms: i64,
        now_ms: i64,
    ) -> Result<Option<CallSignal>, CallError> {
        if now_ms >= expires_at_ms {
            return Err(CallError::Expired);
        }
        match &self.state {
            CallState::Idle | CallState::Ended { .. } => {
                self.state = CallState::Incoming {
                    call_id,
                    peer_id: caller_id,
                    offered_at_ms,
                    expires_at_ms,
                };
                Ok(None)
            }
            CallState::Outgoing {
                call_id: local_call,
                peer_id,
                ..
            } if peer_id == &caller_id => {
                if local_call <= &call_id {
                    Ok(Some(CallSignal::Reject {
                        call_id,
                        reason: CallEndReason::Busy,
                    }))
                } else {
                    self.state = CallState::Incoming {
                        call_id,
                        peer_id: caller_id,
                        offered_at_ms,
                        expires_at_ms,
                    };
                    Ok(None)
                }
            }
            _ => Ok(Some(CallSignal::Reject {
                call_id,
                reason: CallEndReason::Busy,
            })),
        }
    }

    pub fn answer(&mut self, now_ms: i64) -> Result<CallSignal, CallError> {
        let CallState::Incoming {
            call_id,
            peer_id,
            expires_at_ms,
            ..
        } = &self.state
        else {
            return Err(CallError::InvalidState);
        };
        if now_ms >= *expires_at_ms {
            return Err(CallError::Expired);
        }
        let signal = CallSignal::Answer {
            call_id: call_id.clone(),
        };
        self.state = CallState::Connecting {
            call_id: call_id.clone(),
            peer_id: peer_id.clone(),
        };
        Ok(signal)
    }

    pub fn receive_answer(&mut self, call_id: &CallId) -> Result<(), CallError> {
        let CallState::Outgoing {
            call_id: current,
            peer_id,
            ..
        } = &self.state
        else {
            return Err(CallError::InvalidState);
        };
        if current != call_id {
            return Err(CallError::WrongCall);
        }
        self.state = CallState::Connecting {
            call_id: current.clone(),
            peer_id: peer_id.clone(),
        };
        Ok(())
    }

    pub fn transport_connected(&mut self, now_ms: i64) -> Result<(), CallError> {
        let CallState::Connecting { call_id, peer_id } = &self.state else {
            return Err(CallError::InvalidState);
        };
        self.state = CallState::Active {
            call_id: call_id.clone(),
            peer_id: peer_id.clone(),
            connected_at_ms: now_ms,
        };
        Ok(())
    }

    pub fn transport_lost(&mut self, deadline_ms: i64) -> Result<(), CallError> {
        let (call_id, peer_id) = match &self.state {
            CallState::Active {
                call_id, peer_id, ..
            }
            | CallState::Connecting { call_id, peer_id } => (call_id.clone(), peer_id.clone()),
            _ => return Err(CallError::InvalidState),
        };
        self.state = CallState::Reconnecting {
            call_id,
            peer_id,
            deadline_ms,
        };
        Ok(())
    }

    pub fn reconnect(&mut self, now_ms: i64) -> Result<(), CallError> {
        let CallState::Reconnecting {
            call_id,
            peer_id,
            deadline_ms,
        } = &self.state
        else {
            return Err(CallError::InvalidState);
        };
        if now_ms > *deadline_ms {
            return Err(CallError::Expired);
        }
        self.state = CallState::Active {
            call_id: call_id.clone(),
            peer_id: peer_id.clone(),
            connected_at_ms: now_ms,
        };
        Ok(())
    }

    pub fn reject(&mut self, now_ms: i64) -> Result<CallSignal, CallError> {
        let CallState::Incoming {
            call_id, peer_id, ..
        } = &self.state
        else {
            return Err(CallError::InvalidState);
        };
        let signal = CallSignal::Reject {
            call_id: call_id.clone(),
            reason: CallEndReason::Rejected,
        };
        self.state = CallState::Ended {
            call_id: call_id.clone(),
            peer_id: peer_id.clone(),
            reason: CallEndReason::Rejected,
            ended_at_ms: now_ms,
        };
        Ok(signal)
    }

    pub fn end(&mut self, now_ms: i64) -> Result<CallSignal, CallError> {
        let (call_id, peer_id) = active_identity(&self.state).ok_or(CallError::InvalidState)?;
        let signal = CallSignal::End {
            call_id: call_id.clone(),
            reason: CallEndReason::LocalEnded,
        };
        self.state = CallState::Ended {
            call_id,
            peer_id,
            reason: CallEndReason::LocalEnded,
            ended_at_ms: now_ms,
        };
        Ok(signal)
    }

    pub fn receive_termination(
        &mut self,
        signal: &CallSignal,
        now_ms: i64,
    ) -> Result<(), CallError> {
        let (call_id, reason) = match signal {
            CallSignal::Reject { call_id, reason } | CallSignal::End { call_id, reason } => {
                (call_id, reason.clone())
            }
            CallSignal::Offer { .. } | CallSignal::Answer { .. } => {
                return Err(CallError::InvalidState);
            }
        };
        let (current_call, peer_id) =
            active_identity(&self.state).ok_or(CallError::InvalidState)?;
        if &current_call != call_id {
            return Err(CallError::WrongCall);
        }
        self.state = CallState::Ended {
            call_id: current_call,
            peer_id,
            reason,
            ended_at_ms: now_ms,
        };
        Ok(())
    }

    pub fn tick(&mut self, now_ms: i64) {
        let timed_out = match &self.state {
            CallState::Outgoing {
                call_id,
                peer_id,
                expires_at_ms,
                ..
            } if now_ms >= *expires_at_ms => Some((
                call_id.clone(),
                peer_id.clone(),
                CallEndReason::OfferExpired,
            )),
            CallState::Incoming {
                call_id,
                peer_id,
                expires_at_ms,
                ..
            } if now_ms >= *expires_at_ms => Some((
                call_id.clone(),
                peer_id.clone(),
                CallEndReason::OfferExpired,
            )),
            CallState::Reconnecting {
                call_id,
                peer_id,
                deadline_ms,
            } if now_ms > *deadline_ms => Some((
                call_id.clone(),
                peer_id.clone(),
                CallEndReason::ConnectionLost,
            )),
            _ => None,
        };
        if let Some((call_id, peer_id, reason)) = timed_out {
            self.state = CallState::Ended {
                call_id,
                peer_id,
                reason,
                ended_at_ms: now_ms,
            };
        }
    }
}

fn active_identity(state: &CallState) -> Option<(CallId, PeerId)> {
    match state {
        CallState::Outgoing {
            call_id, peer_id, ..
        }
        | CallState::Incoming {
            call_id, peer_id, ..
        }
        | CallState::Connecting { call_id, peer_id }
        | CallState::Active {
            call_id, peer_id, ..
        }
        | CallState::Reconnecting {
            call_id, peer_id, ..
        } => Some((call_id.clone(), peer_id.clone())),
        CallState::Idle | CallState::Ended { .. } => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn call_connects_retries_and_times_out() {
        let mut call = CallMachine::new(PeerId::from("a"));
        let offer = call.start(PeerId::from("b"), 0, 30_000).unwrap();
        let CallSignal::Offer { call_id, .. } = offer else {
            panic!("expected offer")
        };
        call.receive_answer(&call_id).unwrap();
        call.transport_connected(1_000).unwrap();
        assert!(matches!(call.state(), CallState::Active { .. }));
        call.transport_lost(4_000).unwrap();
        assert!(matches!(call.state(), CallState::Reconnecting { .. }));
        call.tick(4_001);
        assert!(matches!(
            call.state(),
            CallState::Ended {
                reason: CallEndReason::ConnectionLost,
                ..
            }
        ));
    }

    #[test]
    fn simultaneous_offers_choose_same_call_id() {
        let mut a = CallMachine::new(PeerId::from("a"));
        let mut b = CallMachine::new(PeerId::from("b"));
        let CallSignal::Offer {
            call_id: call_a, ..
        } = a.start(PeerId::from("b"), 0, 100).unwrap()
        else {
            unreachable!()
        };
        let CallSignal::Offer {
            call_id: call_b, ..
        } = b.start(PeerId::from("a"), 0, 100).unwrap()
        else {
            unreachable!()
        };
        a.receive_offer(call_b.clone(), PeerId::from("b"), 0, 100, 1)
            .unwrap();
        b.receive_offer(call_a.clone(), PeerId::from("a"), 0, 100, 1)
            .unwrap();
        let winner = call_a.min(call_b);
        let state_a_id = active_identity(a.state()).unwrap().0;
        let state_b_id = active_identity(b.state()).unwrap().0;
        assert_eq!(state_a_id, winner);
        assert_eq!(state_b_id, winner);
    }
}
